// Copyright 2021 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

//===- LoweringConfig.h - Declares configuration for lowering Linalg ops --===//
//
// This file declares an attribute that drives how a dispatch region containing
// a set of operations are lowered. The attribute itself is attached to Linalg
// operations, and help converting a Linalg operation into "scalar code".
//
//===----------------------------------------------------------------------===//

#ifndef IREE_COMPILER_CONVERSION_COMMON_LOWERINGCONFIG_H_
#define IREE_COMPILER_CONVERSION_COMMON_LOWERINGCONFIG_H_

#include "iree/compiler/Codegen/Utils/Utils.h"
#include "iree/compiler/Dialect/HAL/IR/HALOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinAttributes.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/BuiltinTypes.h"

namespace mlir {
namespace iree_compiler {
/// Typedef for tile sizes to use at different levels of tiling.
using TileSizesListType = SmallVector<SmallVector<int64_t>>;
using TileSizesListTypeRef = ArrayRef<SmallVector<int64_t>>;
}  // namespace iree_compiler
}  // namespace mlir

// clang-format off
#include "iree/compiler/Codegen/Dialect/LoweringConfigEnums.h.inc"
#define GET_ATTRDEF_CLASSES
#include "iree/compiler/Codegen/Dialect/LoweringConfig.h.inc"
// clang-format on

namespace mlir {
namespace iree_compiler {
//===----------------------------------------------------------------------===//
// Helpers for getting/setting iree_codegen.translation.info attribute on the
// `hal.executable.entry_point`
// ===----------------------------------------------------------------------===//

/// Gets the translate executable info attribute value associated with
/// `entryPointOp`. It expects that the attribute is stored using the identifier
/// `translation.info`.
IREE::Codegen::TranslationInfoAttr getTranslationInfo(
    IREE::HAL::ExecutableEntryPointOp entryPointOp);
/// Returns the translation info for the `funcOp` (by looking at the entry
/// point). Returns `nullptr` on failure.
inline IREE::Codegen::TranslationInfoAttr getTranslationInfo(FuncOp funcOp) {
  auto entryPointOp = getEntryPoint(funcOp);
  if (!entryPointOp) return nullptr;
  return getTranslationInfo(entryPointOp);
}

/// Returns the workgroup size specified on the `entryPointOp`.
SmallVector<int64_t> getWorkgroupSize(
    IREE::HAL::ExecutableEntryPointOp entryPointOp);

/// Set the translate executable info with the entry point op. Overwrites the
/// existing attributes.
// TODO(ravishankarm, benvanik): Eventually all the information needed for the
// lowering will be consolidated into a single attribute with richer
// information.
void setTranslationInfo(IREE::HAL::ExecutableEntryPointOp entryPointOp,
                        IREE::Codegen::TranslationInfoAttr translationInfo,
                        ArrayRef<int64_t> workgroupSize = {});
inline void setTranslationInfo(
    FuncOp entryPointFn, IREE::Codegen::TranslationInfoAttr translationInfo,
    ArrayRef<int64_t> workgroupSize = {}) {
  auto entryPointOp = getEntryPoint(entryPointFn);
  return setTranslationInfo(entryPointOp, translationInfo, workgroupSize);
}

/// Sets the translation info on the `hal.executable.entry_point` op
/// corresponding to the `entryPointFn`. Returns failure if a translation info
/// is already set on the entry point op and is incompatible with what is being
/// set.
inline void setTranslationInfo(
    FuncOp entryPointFn,
    IREE::Codegen::DispatchLoweringPassPipeline passPipeline,
    ArrayRef<int64_t> workloadPerWorkgroup, ArrayRef<int64_t> workgroupSize) {
  auto entryPointOp = getEntryPoint(entryPointFn);
  MLIRContext *context = entryPointFn.getContext();
  auto translationInfo = IREE::Codegen::TranslationInfoAttr::get(
      context, passPipeline, workloadPerWorkgroup);
  setTranslationInfo(entryPointOp, translationInfo, workgroupSize);
}

//===----------------------------------------------------------------------===//
// Helpers for getting/setting `iree_codegen.lowering.config` attribute on root
// operations.
// ===----------------------------------------------------------------------===//

/// Returns the lowering configuration set for an operation. Returns `nullptr`
/// if no value is set.  It expects that the attribute is stored using the
/// identifier `lowering.config`.
IREE::Codegen::LoweringConfigAttr getLoweringConfig(Operation *op);

/// Returns the tile sizes for a particular operation if the
/// `iree_codegen.lowering.config` attribute is set on it.
SmallVector<int64_t> getTileSizes(Operation *op, unsigned level);
SmallVector<Value, 4> getTileSizes(OpBuilder &b, Operation *op, unsigned level);

/// Sets the lowering configuration, overwriting existing attribute values.
void setLoweringConfig(Operation *op, IREE::Codegen::LoweringConfigAttr config);

/// Sets translation for the entry-point function based on op configuration.
inline LogicalResult setOpConfigAndEntryPointFnTranslation(
    FuncOp entryPointFn, Operation *op,
    IREE::Codegen::LoweringConfigAttr config,
    IREE::Codegen::DispatchLoweringPassPipeline passPipeline,
    ArrayRef<int64_t> workgroupSize = {}) {
  auto translationInfo = IREE::Codegen::TranslationInfoAttr::get(
      entryPointFn->getContext(), passPipeline, ArrayRef<int64_t>{});
  setTranslationInfo(entryPointFn, translationInfo, workgroupSize);
  return success();
}
inline LogicalResult setOpConfigAndEntryPointFnTranslation(
    FuncOp entryPointFn, Operation *op, TileSizesListTypeRef tileSizes,
    ArrayRef<int64_t> nativeVectorSize,
    IREE::Codegen::DispatchLoweringPassPipeline passPipeline,
    ArrayRef<int64_t> workgroupSize = {}) {
  MLIRContext *context = entryPointFn.getContext();
  auto config = IREE::Codegen::LoweringConfigAttr::get(context, tileSizes,
                                                       nativeVectorSize);
  setLoweringConfig(op, config);
  return setOpConfigAndEntryPointFnTranslation(entryPointFn, op, config,
                                               passPipeline, workgroupSize);
}

//===----------------------------------------------------------------------===//
// Helpers for getting/setting `iree_codegen.compilation.info` attribute on root
// operations to override IREEs default compilation.
// ===----------------------------------------------------------------------===//

/// Returns the `#iree_codegen.compilation.info` set on the operation. Assumes
/// that the identifier used is `compilation.info`.
IREE::Codegen::CompilationInfoAttr getCompilationInfo(Operation *op);

/// Sets the `config` to use for compiling the operation. If `op` is the root
/// operation of the dispatch region, overrides the default configuration that
/// is used for compilation.
void setCompilationInfo(Operation *op,
                        IREE::Codegen::CompilationInfoAttr config);

/// Removes the `#iree_codegen.compilation.info` attribute that is set on the
/// operation.
void eraseCompilationInfo(Operation *op);

}  // namespace iree_compiler
}  // namespace mlir

#endif  // IREE_COMPILER_CONVERSION_COMMON_LOWERINGCONFIG_H_
