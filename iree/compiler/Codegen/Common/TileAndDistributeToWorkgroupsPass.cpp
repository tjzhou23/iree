// Copyright 2022 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

//=== TileAndDistributeToWorkgroupsPass.cpp - Tile to workgroups pass ----===//
//
// This pass distributes the operations within the module to workgroups. This
// pass is created to move tile and distribution out of flow level and into
// the backends. For now this is mostly a bridge pass to connect things during
// the transition, and eventually might just be deprecated in favor of a
// utility method.
//
//===---------------------------------------------------------------------===//
#include "iree-dialects/Dialect/LinalgExt/IR/LinalgExtOps.h"
#include "iree-dialects/Dialect/LinalgExt/Transforms/Transforms.h"
#include "iree/compiler/Codegen/Common/DestructiveUpdateUtils.h"
#include "iree/compiler/Codegen/Dialect/LoweringConfig.h"
#include "iree/compiler/Codegen/PassDetail.h"
#include "iree/compiler/Codegen/Passes.h"
#include "iree/compiler/Codegen/Transforms/Transforms.h"
#include "iree/compiler/Codegen/Utils/Utils.h"
#include "iree/compiler/Dialect/Flow/IR/FlowOps.h"
#include "iree/compiler/Dialect/Flow/IR/PartitionableLoopsInterface.h"
#include "iree/compiler/Dialect/HAL/IR/HALDialect.h"
#include "iree/compiler/Dialect/HAL/IR/HALOps.h"
#include "mlir/Dialect/MemRef/Transforms/Passes.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#define DEBUG_TYPE "iree-codegen-tile-and-distribute-to-workgroups"

namespace mlir {
namespace iree_compiler {

//===---------------------------------------------------------------------===//
// Patterns and methods for tile and distribute of Linalg ops to workgroups.
//===---------------------------------------------------------------------===//

// Get the lowering configuration for the operation within the dispatch.
// This looks for tile sizes by looking for lowering configuration.
static FailureOr<SmallVector<int64_t>> getTileSizesFromLoweringConfig(
    ArrayRef<Operation *> computeOps, MLIRContext *context) {
  if (computeOps.empty()) return SmallVector<int64_t>{};

  Optional<SmallVector<int64_t>> distributedTileSizes;
  for (auto op : computeOps) {
    auto partitionbleLoopInterface =
        dyn_cast<IREE::Flow::PartitionableLoopsInterface>(op);
    if (!partitionbleLoopInterface) continue;
    IREE::Codegen::LoweringConfigAttr currLoweringConfig =
        getLoweringConfig(op);
    if (!currLoweringConfig) continue;
    SmallVector<unsigned> partitionableLoops =
        partitionbleLoopInterface.getPartitionableLoops(kNumMaxParallelDims);
    SmallVector<int64_t> tileSizes = currLoweringConfig.getTileSizeVals(0);
    SmallVector<int64_t> currDistributedTileSizes;
    for (auto loopID : partitionableLoops) {
      // If there is a tile size for this loop, use that value, or use zero to
      // specify untiled loop.
      if (loopID < tileSizes.size()) {
        currDistributedTileSizes.push_back(tileSizes[loopID]);
      } else {
        currDistributedTileSizes.push_back(0);
      }
    }
    if (distributedTileSizes) {
      if (currDistributedTileSizes != distributedTileSizes) {
        // Inconsistent distributed tile sizes. Abort.
        return static_cast<LogicalResult>(
            computeOps.front()->emitOpError("inconsistent distribution of ops "
                                            "for first level of distribution"));
      }
    } else {
      distributedTileSizes = currDistributedTileSizes;
    }
  }
  if (distributedTileSizes) {
    return distributedTileSizes.getValue();
  }
  return SmallVector<int64_t>{};
}

/// Defines the workgroup count region if the tile size for the distributed
/// loops are known.
static LogicalResult defineWorkgroupCountRegion(
    FuncOp entryPointFn, ArrayRef<int64_t> distributedLoopTileSizes) {
  if (distributedLoopTileSizes.size() > kNumMaxParallelDims) {
    // For now error out here.
    return entryPointFn.emitOpError(
               "expected number of distributed loop tile sizes to be less than "
               "or equal to ")
           << kNumMaxParallelDims;
  }
  WorkgroupCountRegionBuilder regionBuilder =
      [&distributedLoopTileSizes](
          OpBuilder &b, Location loc,
          std::array<Value, 3> workload) -> std::array<Value, 3> {
    Value one = b.create<arith::ConstantIndexOp>(loc, 1);
    std::array<Value, 3> numWorkgroups = {one, one, one};
    for (auto it : llvm::enumerate(llvm::reverse(distributedLoopTileSizes))) {
      // If tile size is 0, it implies this isnt tiled, and the number of
      // workgroups is 1, i.e. the default.
      if (it.value() == 0) continue;
      numWorkgroups[it.index()] = applyMapToValues(
          b, loc,
          AffineMap::get(0, 1, b.getAffineSymbolExpr(0).ceilDiv(it.value())),
          workload[it.index()])[0];
    }
    return numWorkgroups;
  };
  OpBuilder builder(entryPointFn.getContext());
  return defineWorkgroupCountRegion(builder, entryPointFn, regionBuilder);
}

/// Update the workload_per_wg value on the TranslationInfoAttr.
// TODO(ravishankarm): The workload_per_wg field should be deprecated. This
// is just transition before all dependencies on it can be removed.
static LogicalResult updateTranslationInfoAttr(
    FuncOp entryPointFn, ArrayRef<int64_t> distributedLoopTileSizes) {
  auto entryPointOp = getEntryPoint(entryPointFn);
  if (!entryPointOp) {
    return entryPointFn.emitOpError("expected entry point function");
  }
  IREE::Codegen::DispatchLoweringPassPipeline passPipeline =
      IREE::Codegen::DispatchLoweringPassPipeline::CPUDefault;
  if (auto translationInfo = getTranslationInfo(entryPointOp)) {
    // Expect the `workload_per_wg` to be empty.
    if (!translationInfo.getWorkloadPerWorkgroupVals().empty()) {
      return entryPointFn.emitOpError(
          "expected workload_per_wg to be empty at this stage");
    }
    passPipeline = translationInfo.getDispatchLoweringPassPipeline();
  }
  SmallVector<int64_t> workloadPerWorkgroup =
      llvm::to_vector(llvm::reverse(distributedLoopTileSizes));
  auto newTranslationInfoAttr = IREE::Codegen::TranslationInfoAttr::get(
      entryPointFn.getContext(), passPipeline, workloadPerWorkgroup);
  setTranslationInfo(entryPointOp, newTranslationInfoAttr);
  return success();
}

// Pull in producers into the tiled operation.
static void pullInProducers(linalg::LinalgOp tiledOp,
                            ValueRange untiledOperands,
                            PatternRewriter &rewriter) {
  for (auto en : llvm::enumerate(untiledOperands)) {
    auto producer = en.value().getDefiningOp<linalg::LinalgOp>();
    if (!producer) continue;

    OpResult opResult = en.value().cast<OpResult>();
    auto maybeFusionInfo = linalg::fuseProducerOfTensor(
        rewriter, producer->getResult(opResult.getResultNumber()),
        tiledOp->getOpOperand(en.index()));
    if (failed(maybeFusionInfo)) continue;

    // If the fusion was successfull recurse over the current producers operands
    // and fuse them in as well.
    SmallVector<Value> origProducerOperands =
        producer.getInputAndOutputOperands();
    pullInProducers(maybeFusionInfo->fusedProducer, origProducerOperands,
                    rewriter);
  }
}

namespace {
// Rewrite pattern to ensure only ops with tensor semantics are tiled.
struct TileAndDistributeLinalgOpsPattern : public linalg::LinalgTilingPattern {
  using Base = linalg::LinalgTilingPattern;
  TileAndDistributeLinalgOpsPattern(MLIRContext *context,
                                    linalg::LinalgTilingOptions options,
                                    linalg::LinalgTransformationFilter marker,
                                    PatternBenefit benefit = 1)
      : Base(context, options, marker, benefit) {}

  LogicalResult matchAndRewrite(linalg::LinalgOp linalgOp,
                                PatternRewriter &rewriter) const override {
    SmallVector<Value> untiledOperands = linalgOp.getInputAndOutputOperands();
    FailureOr<linalg::TiledLinalgOp> tiledLinalgOpOr =
        Base::returningMatchAndRewrite(linalgOp, rewriter);
    if (failed(tiledLinalgOpOr)) {
      return failure();
    }
    if (tiledLinalgOpOr->loops.empty()) {
      // If there are no loops, there is nothing to do.
      return success();
    }
    pullInProducers(tiledLinalgOpOr->op, untiledOperands, rewriter);
    return success();
  }
};
}  // namespace

namespace {
struct TileAndDistributeToWorkgroupsPass
    : public TileAndDistributeToWorkgroupsBase<
          TileAndDistributeToWorkgroupsPass> {
  void getDependentDialects(DialectRegistry &registry) const override {
    registry.insert<AffineDialect, IREE::Flow::FlowDialect,
                    IREE::HAL::HALDialect, linalg::LinalgDialect,
                    scf::SCFDialect, tensor::TensorDialect>();
  }

  void runOnOperation() override;
};
}  // namespace

template <typename OpTy>
static Value buildHALWorkgroupInfoOp(OpBuilder &b, unsigned dim) {
  return b.template create<OpTy>(b.getInsertionPoint()->getLoc(), dim);
}

void TileAndDistributeToWorkgroupsPass::runOnOperation() {
  MLIRContext *context = &getContext();
  FuncOp funcOp = getOperation();
  if (!isEntryPoint(funcOp)) return;

  SmallVector<Operation *> computeOps;
  SmallVector<LoopTilingAndDistributionInfo> tiledLoops;
  if (failed(getComputeOps(funcOp, computeOps, tiledLoops))) {
    return signalPassFailure();
  }
  if (!tiledLoops.empty()) {
    // The entry point already has distribution to workgroups. Do nothing.
    return;
  }
  if (computeOps.empty()) {
    // Ignore other operations.
    return;
  }

  // Get the tile sizes to use from lowering configuration if set.
  FailureOr<SmallVector<int64_t>> configTileSizes =
      getTileSizesFromLoweringConfig(computeOps, context);
  if (failed(configTileSizes)) {
    return signalPassFailure();
  }

  if (failed(defineWorkgroupCountRegion(funcOp, configTileSizes.getValue())) ||
      failed(updateTranslationInfoAttr(funcOp, configTileSizes.getValue()))) {
    return signalPassFailure();
  }

  // Add a marker to the last operation in the list.
  auto marker = StringAttr::get(context, "__workgroup_tiling__");
  computeOps.back()->setAttr(linalg::LinalgTransforms::kLinalgTransformMarker,
                             marker);

  // Configure the linalg options.
  // Distribute the ops using the flow workgroup ID/Count operations.
  static linalg::LinalgLoopDistributionOptions workgroupDistributionOptions = {
      [](OpBuilder &builder, Location loc, ArrayRef<Range> parallelLoopRanges) {
        auto numParallelDims = parallelLoopRanges.size();

        SmallVector<linalg::ProcInfo, 3> procInfo(numParallelDims);
        for (size_t dim = 0; dim < numParallelDims; ++dim) {
          procInfo[numParallelDims - dim - 1] = {
              buildHALWorkgroupInfoOp<IREE::HAL::InterfaceWorkgroupIDOp>(
                  builder, dim),
              buildHALWorkgroupInfoOp<IREE::HAL::InterfaceWorkgroupCountOp>(
                  builder, dim)};
        }
        return procInfo;
      },
      {linalg::DistributionMethod::Cyclic, linalg::DistributionMethod::Cyclic,
       linalg::DistributionMethod::Cyclic},
      DenseMap<StringRef,
               std::function<linalg::ProcInfo(OpBuilder &, Location)>>()};

  // Tile size selection function.
  auto tileSizeFn = [&](OpBuilder &builder,
                        Operation *op) -> SmallVector<Value, 4> {
    // Check if tile sizes are deduced from the configuration. If so use those.
    if (getLoweringConfig(op)) {
      return getTileSizes(builder, op, 0);
    }

    // TODO(ravishankarm): This part needs to be deleted once all backends
    // configure on untiled ops. By default set the tile size to
    // hal.interface.workgroup.size op, with 0 for the innermost parallel loop
    // partitioned, 1 for the next outermost loop partitioned and so on.  Use
    // the workgroup size as a proxy for tile size here. At the flow level this
    // represents the "workload" per processors and is not necessarily tied to
    // the workgroup size.auto interfaceOp =
    // dyn_cast<IREE::Flow::PartitionableLoopsInterface>(op);
    auto interfaceOp = dyn_cast<IREE::Flow::PartitionableLoopsInterface>(op);
    if (!interfaceOp) return {};
    SmallVector<unsigned> partitionedLoops =
        interfaceOp.getPartitionableLoops(kNumMaxParallelDims);
    if (partitionedLoops.empty()) return {};
    unsigned maxDepth = partitionedLoops.back() + 1;

    // Set all loops not partitioned to tile size 0. and those partitioned to
    // `flow.workgroup.size`.
    auto zero = builder.create<arith::ConstantIndexOp>(op->getLoc(), 0);
    SmallVector<Value, 4> useTileSizes(maxDepth, zero);
    llvm::DenseSet<unsigned> partitionedLoopsSet;
    partitionedLoopsSet.insert(partitionedLoops.begin(),
                               partitionedLoops.end());
    unsigned currFlowDim = 0;
    for (size_t dim = maxDepth; dim > 0; dim--) {
      if (partitionedLoopsSet.count(dim - 1)) {
        useTileSizes[dim - 1] =
            buildHALWorkgroupInfoOp<IREE::HAL::InterfaceWorkgroupSizeOp>(
                builder, currFlowDim++);
      }
    }
    return useTileSizes;
  };

  auto linalgTilingOptions =
      linalg::LinalgTilingOptions()
          .setDistributionOptions(workgroupDistributionOptions)
          .setLoopType(linalg::LinalgTilingLoopType::Loops)
          .setTileSizeComputationFunction(tileSizeFn);

  RewritePatternSet patterns(context);
  patterns.insert<TileAndDistributeLinalgOpsPattern,
                  IREE::LinalgExt::TiledOpInterfaceTilingPattern>(
      context, linalgTilingOptions, linalg::LinalgTransformationFilter(marker));
  if (failed(applyPatternsAndFoldGreedily(funcOp, std::move(patterns)))) {
    return signalPassFailure();
  }

  // Apply linalg tiling optimization patterns.
  RewritePatternSet canonicalizationPatterns(context);
  linalg::populateLinalgTilingCanonicalizationPatterns(
      canonicalizationPatterns);
  memref::populateResolveRankedShapeTypeResultDimsPatterns(
      canonicalizationPatterns);
  if (failed(applyPatternsAndFoldGreedily(
          funcOp, std::move(canonicalizationPatterns)))) {
    return signalPassFailure();
  }

  // Rewrite destructive updates and ensure no remaining store remains to the
  // full output.

  // TODO(#...): Use of the destructive update rewrite is a hack! There needs to
  // be a way to generate loops as we need, and use the tiled op generation
  // implementation. This should be possible after moving everything to use the
  // `TilingInterface`.
  if (failed(rewriteLinalgDestructiveUpdates(funcOp))) {
    funcOp->emitError("Failed to rewrite destructive updates in:\n")
        << *funcOp.getOperation();
    return signalPassFailure();
  }
}

std::unique_ptr<OperationPass<FuncOp>>
createTileAndDistributeToWorkgroupsPass() {
  return std::make_unique<TileAndDistributeToWorkgroupsPass>();
}

}  // namespace iree_compiler
}  // namespace mlir
