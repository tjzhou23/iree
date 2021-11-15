// Copyright 2021 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "iree/compiler/Codegen/Dialect/LoweringConfig.h"
#include "iree/compiler/Codegen/LLVMCPU/KernelDispatch.h"
#include "iree/compiler/Codegen/PassDetail.h"
#include "iree/compiler/Codegen/Passes.h"
#include "iree/compiler/Codegen/Transforms/Transforms.h"
#include "iree/compiler/Codegen/Utils/MarkerUtils.h"
#include "iree/compiler/Codegen/Utils/Utils.h"
#include "mlir/Conversion/VectorToSCF/VectorToSCF.h"
#include "mlir/Dialect/Linalg/IR/LinalgOps.h"
#include "mlir/Dialect/Linalg/Transforms/Hoisting.h"
#include "mlir/Dialect/Linalg/Transforms/Transforms.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/Dialect/MemRef/Transforms/Passes.h"
#include "mlir/Dialect/SCF/Transforms.h"
#include "mlir/Dialect/Vector/VectorTransforms.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#define DEBUG_TYPE "iree-llvmcpu-tile-fuse-and-vectorize"

namespace mlir {
namespace iree_compiler {

namespace {
// Could just be linalg::TilingPattern with a ContractionOpInterface filter, but
// that is always templated on an op.
struct TileWorkgroups : public linalg::LinalgBaseTilingPattern {
  using Base = linalg::LinalgBaseTilingPattern;
  TileWorkgroups(MLIRContext *context, linalg::LinalgTilingOptions options,
                 linalg::LinalgTransformationFilter marker)
      : LinalgBaseTilingPattern(context, options, marker) {}
  LogicalResult matchAndRewrite(Operation *op,
                                PatternRewriter &rewriter) const override {
    auto contractionOp = dyn_cast<linalg::ContractionOpInterface>(op);
    if (!contractionOp) return failure();

    linalg::TiledLinalgOp tiledLinalgOp;
    if (failed(Base::matchAndRewriteBase(op, rewriter, tiledLinalgOp))) {
      return failure();
    }
    rewriter.replaceOp(op, tiledLinalgOp.tensorResults);
    return success();
  }
};

}  // namespace

namespace {
struct LLVMCPUTileFuseAndVectorizePass
    : public LLVMCPUTileFuseAndVectorizeBase<LLVMCPUTileFuseAndVectorizePass> {
  LLVMCPUTileFuseAndVectorizePass(bool vectorize = true)
      : lowerToVectors(vectorize) {}
  LLVMCPUTileFuseAndVectorizePass(const LLVMCPUTileFuseAndVectorizePass &pass) {
    lowerToVectors = pass.lowerToVectors;
  }
  void getDependentDialects(DialectRegistry &registry) const override {
    registry.insert<linalg::LinalgDialect, memref::MemRefDialect,
                    vector::VectorDialect>();
  }
  void runOnOperation() override;

 private:
  bool lowerToVectors;
};

LogicalResult applyTileAndFuseCanonicalizationPatterns(FuncOp funcOp) {
  auto context = funcOp.getContext();
  OwningRewritePatternList patterns(context);
  linalg::populateLinalgTilingCanonicalizationPatterns(patterns);
  tensor::DimOp::getCanonicalizationPatterns(patterns, context);
  memref::DimOp::getCanonicalizationPatterns(patterns, context);
  memref::populateResolveRankedShapeTypeResultDimsPatterns(patterns);
  memref::populateResolveShapedTypeResultDimsPatterns(patterns);
  scf::populateSCFForLoopCanonicalizationPatterns(patterns);
  return applyPatternsAndFoldGreedily(funcOp, std::move(patterns));
}
}  // namespace

void LLVMCPUTileFuseAndVectorizePass::runOnOperation() {
  MLIRContext *context = &getContext();
  auto funcOp = getOperation();

  DEBUG_WITH_TYPE(DEBUG_TYPE, {
    llvm::dbgs() << "\n--- Before LLVMCPUTileFuseAndVectorize ---\n";
    funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
    llvm::dbgs() << "\n\n";
  });

  // Assume there is a single op with a lowering config we use to drive the
  // tiling decisions.
  // TODO(hanchung): Speicify a callback to get tile sizes in tile+fuse after
  // upstream method supports it. Then we don't need extracting the config.
  IREE::Codegen::LoweringConfigAttr config;
  funcOp.walk([&](linalg::LinalgOp linalgOp) {
    if (auto opConfig = getLoweringConfig(linalgOp)) {
      if (opConfig) {
        // Duplicate configurations.
        if (config) return signalPassFailure();
        config = opConfig;
      }
    }
  });

  auto tileAndFuseLinalgOps = [&](TilingLevel level) {
    OpBuilder builder(funcOp.getContext());
    SmallVector<Operation *> computeOps;
    SmallVector<LoopTilingAndDistributionInfo> tiledLoops;
    if (failed(getComputeOps(funcOp, computeOps, tiledLoops))) {
      return signalPassFailure();
    }
    auto tileSizes = config.getTileSizeVals(static_cast<unsigned>(level));
    linalg::LinalgOp consumerOp;
    for (auto iter : llvm::reverse(computeOps)) {
      if (auto op = dyn_cast<linalg::LinalgOp>(iter)) {
        consumerOp = op;
        break;
      }
    }
    assert(consumerOp && "can't find consumerOp");
    SmallVector<int64_t> consumerTileSize(
        tileSizes.begin(),
        tileSizes.begin() + consumerOp.getNumParallelLoops());
    auto identityIndicesOrder =
        llvm::to_vector<4>(llvm::seq<int64_t>(0, consumerTileSize.size()));
    FailureOr<linalg::TileLoopNest> tileLoopNest =
        linalg::tileConsumerAndFuseProducers(
            builder, consumerOp, consumerTileSize, identityIndicesOrder);
    if (failed(tileLoopNest)) return signalPassFailure();
    consumerOp->replaceAllUsesWith(tileLoopNest->getRootOpReplacementResults());

    // Apply canoncalization
    if (failed(applyTileAndFuseCanonicalizationPatterns(funcOp))) {
      return signalPassFailure();
    }
    DEBUG_WITH_TYPE(DEBUG_TYPE, {
      llvm::dbgs() << "\n--- After tile and fuse paralell loops ---\n";
      funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
      llvm::dbgs() << "\n\n";
    });
  };

  tileAndFuseLinalgOps(TilingLevel::L1Tiles);

  // Tile and fuse for vector sizes, then tile reduction loops. We don't rely on
  // unroll vector pass because it could introduce register pressure.
  bool hasMatmulAndIsVectorizable = true;
  {
    tileAndFuseLinalgOps(TilingLevel::VectorTiles);
    OwningRewritePatternList tileReductionPatterns(&getContext());

    funcOp.walk([&](linalg::ContractionOpInterface op) {
      auto linalgOp = dyn_cast<linalg::LinalgOp>(op.getOperation());
      if (failed(linalg::vectorizeLinalgOpPrecondition(linalgOp))) {
        hasMatmulAndIsVectorizable = false;
      }
      auto loopRanges = linalgOp.getStaticLoopRanges();
      if (loopRanges) {
        auto tiles =
            getTileSizes(op, static_cast<unsigned>(TilingLevel::VectorTiles));
        for (int i = linalgOp.getNumParallelLoops(); i < tiles.size(); ++i) {
          if (loopRanges.getValue()[i] == ShapedType::kDynamicSize ||
              (tiles[i] && loopRanges.getValue()[i] % tiles[i] != 0)) {
            hasMatmulAndIsVectorizable = false;
          }
        }
      }
    });
    // If the matmul op is not vectorizable, stop directly.
    // If the follow generic op is not vectorizable, it's fine.
    // If the follow generic op is vectorizable, we can't vectorize it. Because
    // an extra allocation op will be created (to temporarily store the result
    // of matmul.)
    if (!hasMatmulAndIsVectorizable) return;

    tileReductionPatterns.insert<TileWorkgroups>(
        context,
        linalg::LinalgTilingOptions().setTileSizeComputationFunction(
            [](OpBuilder &builder,
               Operation *operation) -> SmallVector<Value, 4> {
              auto tiles =
                  getTileSizes(builder, operation,
                               static_cast<unsigned>(TilingLevel::VectorTiles));
              auto numParallelLoops =
                  dyn_cast<linalg::LinalgOp>(operation).getNumParallelLoops();
              auto zeroTileVal = builder.create<arith::ConstantIndexOp>(
                  operation->getLoc(), 0);
              SmallVector<Value> reductionTiles(tiles.size(), zeroTileVal);
              for (int i = numParallelLoops; i < tiles.size(); ++i) {
                reductionTiles[i] = tiles[i];
              }
              return std::move(reductionTiles);
            }),
        linalg::LinalgTransformationFilter(
            ArrayRef<Identifier>{},
            Identifier::get(getVectorizeMarker(), context)));

    if (failed(applyPatternsAndFoldGreedily(
            funcOp, std::move(tileReductionPatterns)))) {
      return signalPassFailure();
    }
    // Apply canoncalization
    if (failed(applyTileAndFuseCanonicalizationPatterns(funcOp))) {
      return signalPassFailure();
    }
    DEBUG_WITH_TYPE(DEBUG_TYPE, {
      llvm::dbgs() << "\n--- After tiling reduction loops ---\n";
      funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
      llvm::dbgs() << "\n\n";
    });
  }

  if (!lowerToVectors) {
    return;
  }

  {
    // Set vectorization marker globally
    OpBuilder builder(funcOp.getContext());
    funcOp.walk(
        [&](linalg::LinalgOp op) { setMarker(op, getVectorizeMarker()); });
  }

  // Apply vectorization patterns.
  {
    OwningRewritePatternList vectorizationPatterns(&getContext());
    linalg::insertVectorizationPatterns<linalg::ContractionOpInterface,
                                        linalg::GenericOp, linalg::CopyOp,
                                        linalg::FillOp>(
        vectorizationPatterns, linalg::LinalgVectorizationOptions(),
        linalg::LinalgTransformationFilter(
            Identifier::get(getVectorizeMarker(), context)));
    vector::populateVectorTransferPermutationMapLoweringPatterns(
        vectorizationPatterns);
    vector::populateVectorReductionToContractPatterns(vectorizationPatterns);
    if (failed(applyPatternsAndFoldGreedily(
            funcOp, std::move(vectorizationPatterns)))) {
      return signalPassFailure();
    }

    DEBUG_WITH_TYPE(DEBUG_TYPE, {
      llvm::dbgs() << "\n--- After vectorization ---\n";
      funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
      llvm::dbgs() << "\n\n";
    });
  }

  {
    // Fold consumer add ops into the contraction op itself.
    RewritePatternSet canonicalizationPatterns(context);
    vector::ContractionOp::getCanonicalizationPatterns(canonicalizationPatterns,
                                                       context);
    (void)applyPatternsAndFoldGreedily(funcOp,
                                       std::move(canonicalizationPatterns));

    DEBUG_WITH_TYPE(DEBUG_TYPE, {
      llvm::dbgs()
          << "\n--- After folding consumer add ops into contraction op "
             "iteself ---\n";
      funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
      llvm::dbgs() << "\n\n";
    });
  }

  linalg::hoistRedundantVectorTransfersOnTensor(funcOp);
  linalg::hoistRedundantVectorTransfers(funcOp);
  DEBUG_WITH_TYPE(DEBUG_TYPE, {
    llvm::dbgs() << "--- After hoisting vector transfers ---\n";
    funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
    llvm::dbgs() << "\n\n";
  });

  // Apply vector specific operation lowering.
  {
    vector::VectorTransformsOptions vectorTransformsOptions =
        vector::VectorTransformsOptions().setVectorTransformsOptions(
            vector::VectorContractLowering::OuterProduct);
    OwningRewritePatternList vectorContractLoweringPatterns(&getContext());
    vectorContractLoweringPatterns.insert<
        vector::ContractionOpToOuterProductOpLowering,
        vector::ContractionOpToMatmulOpLowering, vector::ContractionOpLowering>(
        vectorTransformsOptions, context);
    vector::populateVectorTransferPermutationMapLoweringPatterns(
        vectorContractLoweringPatterns);
    if (failed(applyPatternsAndFoldGreedily(
            funcOp, std::move(vectorContractLoweringPatterns)))) {
      return signalPassFailure();
    }

    DEBUG_WITH_TYPE(DEBUG_TYPE, {
      llvm::dbgs() << "\n--- After vector specific operatrion lowering ---\n";
      funcOp.print(llvm::dbgs(), OpPrintingFlags().useLocalScope());
      llvm::dbgs() << "\n\n";
    });
  }
}

std::unique_ptr<OperationPass<FuncOp>> createLLVMCPUTileFuseAndVectorizePass(
    bool lowerToVectors) {
  return std::make_unique<LLVMCPUTileFuseAndVectorizePass>(lowerToVectors);
}

}  // namespace iree_compiler
}  // namespace mlir