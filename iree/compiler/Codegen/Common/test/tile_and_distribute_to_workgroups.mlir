// RUN: iree-opt -pass-pipeline='hal.executable(hal.executable.variant(builtin.module(builtin.func(iree-codegen-tile-and-distribute-to-workgroups)))), canonicalize, cse' -split-input-file %s | FileCheck %s

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 64, 0], [16, 4, 64], [4, 4, 4]], native_vector_size = [4, 4, 4]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>,
    #hal.descriptor_set.binding<3, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_arm_64_ = #hal.executable.target<"llvm", "embedded-elf-arm_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "aarch64-unknown-unknown-eabi-elf"
}>
#translation = #iree_codegen.translation.info<"CPUTileFuseAndVectorize", workload_per_wg = []>
hal.executable private @matmul_tensors {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_arm_64_ {
    hal.executable.entry_point public @matmul_tensors layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @matmul_tensors() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %2}
        %4 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%2, %1}
        %5 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %1}
        %6 = hal.interface.binding.subspan set(0) binding(3) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:?x?xf32>{%0, %1}
        %7 = flow.dispatch.tensor.load %3, offsets = [0, 0], sizes = [%0, %2], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %2} -> tensor<?x?xf32>
        %8 = flow.dispatch.tensor.load %4, offsets = [0, 0], sizes = [%2, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%2, %1} -> tensor<?x?xf32>
        %9 = flow.dispatch.tensor.load %5, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %1} -> tensor<?x?xf32>
        %10 = linalg.matmul {lowering.config = #config}
            ins(%7, %8 : tensor<?x?xf32>, tensor<?x?xf32>) outs(%9 : tensor<?x?xf32>) -> tensor<?x?xf32>
        flow.dispatch.tensor.store %10, %6, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : tensor<?x?xf32> -> !flow.dispatch.tensor<writeonly:?x?xf32>{%0, %1}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 * 64)>
//  CHECK-DAG: #[[MAP2:.+]] = affine_map<(d0)[s0] -> (64, -d0 + s0)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUTileFuseAndVectorize", workload_per_wg = [64, 64]>
//      CHECK: hal.executable.entry_point public @matmul_tensors
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-NEXT:   (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:    %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:    %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:    %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:    %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:    %[[D1:.+]] = affine.apply #[[MAP0]]()[%[[ARG1]]]
//      CHECK:    hal.return %[[D0]], %[[D1]], %[[C1]] : index, index, index
//      CHECK: func @matmul_tensors()
//  CHECK-DAG:   %[[M:.+]] = hal.interface.constant.load[0]
//  CHECK-DAG:   %[[N:.+]] = hal.interface.constant.load[1]
//  CHECK-DAG:   %[[K:.+]] = hal.interface.constant.load[2]
//  CHECK-DAG:   %[[LHS_BINDING:.+]] = hal.interface.binding.subspan set(0) binding(0)
//  CHECK-DAG:   %[[RHS_BINDING:.+]] = hal.interface.binding.subspan set(0) binding(1)
//  CHECK-DAG:   %[[INIT_BINDING:.+]] = hal.interface.binding.subspan set(0) binding(2)
//  CHECK-DAG:   %[[OUT_BINDING:.+]] = hal.interface.binding.subspan set(0) binding(3)
//  CHECK-DAG:   %[[WG_ID_X:.+]] = hal.interface.workgroup.id[0]
//  CHECK-DAG:   %[[WG_COUNT_X:.+]] = hal.interface.workgroup.count[0]
//  CHECK-DAG:   %[[WG_ID_Y:.+]] = hal.interface.workgroup.id[1]
//  CHECK-DAG:   %[[WG_COUNT_Y:.+]] = hal.interface.workgroup.count[1]
//  CHECK-DAG:   %[[LB_Y:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_Y]]]
//  CHECK-DAG:   %[[STEP_Y:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_Y]]]
//      CHECK:   scf.for %[[IV0:.+]] = %[[LB_Y]] to %[[M]] step %[[STEP_Y]]
//  CHECK-DAG:     %[[LB_X:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_X]]]
//  CHECK-DAG:     %[[STEP_X:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_X]]]
//      CHECK:     scf.for %[[IV1:.+]] = %[[LB_X]] to %[[N]] step %[[STEP_X]]
//  CHECK-DAG:       %[[TILESIZE_M:.+]] = affine.min #[[MAP2]](%[[IV0]])[%[[M]]]
//  CHECK-DAG:       %[[LHS:.+]] = flow.dispatch.tensor.load %[[LHS_BINDING]]
// CHECK-SAME:           offsets = [%[[IV0]], 0], sizes = [%[[TILESIZE_M]], %[[K]]]
//  CHECK-DAG:       %[[TILESIZE_N:.+]] = affine.min #[[MAP2]](%[[IV1]])[%[[N]]]
//  CHECK-DAG:       %[[RHS:.+]] = flow.dispatch.tensor.load %[[RHS_BINDING]]
// CHECK-SAME:           offsets = [0, %[[IV1]]], sizes = [%[[K]], %[[TILESIZE_N]]]
//  CHECK-DAG:       %[[INIT:.+]] = flow.dispatch.tensor.load %[[INIT_BINDING]]
// CHECK-SAME:           offsets = [%[[IV0]], %[[IV1]]], sizes = [%[[TILESIZE_M]], %[[TILESIZE_N]]]
//      CHECK:       %[[GEMM:.+]] = linalg.matmul
// CHECK-SAME:           ins(%[[LHS]], %[[RHS]] :
// CHECK-SAME:           outs(%[[INIT]] :
//      CHECK:       flow.dispatch.tensor.store %[[GEMM]], %[[OUT_BINDING]]
// CHECK-SAME:           offsets = [%[[IV0]], %[[IV1]]], sizes = [%[[TILESIZE_M]], %[[TILESIZE_N]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 64], [1, 4], [0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"
}>
#map0 = affine_map<(d0, d1) -> (d0, d1)>
#map1 = affine_map<(d0, d1) -> (d1)>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @add {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @add layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @add() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %1}
        %3 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?xf32>{%1}
        %4 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:?x?xf32>{%0, %1}
        %5 = flow.dispatch.tensor.load %2, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %1} -> tensor<?x?xf32>
        %6 = flow.dispatch.tensor.load %3, offsets = [0], sizes = [%1], strides = [1]
            : !flow.dispatch.tensor<readonly:?xf32>{%1} -> tensor<?xf32>
        %7 = linalg.init_tensor [%0, %1] : tensor<?x?xf32>
        %8 = linalg.generic {
            indexing_maps = [#map0, #map1, #map0], iterator_types = ["parallel", "parallel"]}
            ins(%5, %6 : tensor<?x?xf32>, tensor<?xf32>) outs(%7 : tensor<?x?xf32>)
            attrs =  {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32, %arg2: f32):
          %9 = arith.addf %arg0, %arg1 : f32
          linalg.yield %9 : f32
        } -> tensor<?x?xf32>
        flow.dispatch.tensor.store %8, %4, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : tensor<?x?xf32> -> !flow.dispatch.tensor<writeonly:?x?xf32>{%0, %1}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [64, 64]>
//      CHECK: hal.executable private @add
//      CHECK: hal.executable.entry_point public @add
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[C1]] : index, index, index
//      CHECK: func @add()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       %[[RESULT:.+]] = linalg.generic
//      CHECK:       flow.dispatch.tensor.store %[[RESULT]], %{{.+}}, offsets = [%[[IV0]], %[[IV1]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 64, 64, 64], [1, 1, 1, 4], [0, 0, 0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>,
    #hal.descriptor_set.binding<3, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"}>
#map = affine_map<(d0, d1, d2, d3) -> (d0, d1, d2, d3)>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @add4D {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @add4D layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @add4D() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.constant.load[3] : index
        %4 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) alignment(32)
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%0, %1, %2, %3}
        %5 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) alignment(32)
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%0, %1, %2, %3}
        %6 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) alignment(32)
            : !flow.dispatch.tensor<writeonly:?x?x?x?xf32>{%0, %1, %2, %3}
        %7 = flow.dispatch.tensor.load %4, offsets = [0, 0, 0, 0], sizes = [%0, %1, %2, %3], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%0, %1, %2, %3} -> tensor<?x?x?x?xf32>
        %8 = flow.dispatch.tensor.load %5, offsets = [0, 0, 0, 0], sizes = [%0, %1, %2, %3], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%0, %1, %2, %3} -> tensor<?x?x?x?xf32>
        %9 = linalg.init_tensor [%0, %1, %2, %3] : tensor<?x?x?x?xf32>
        %10 = linalg.generic {
            indexing_maps = [#map, #map, #map], iterator_types = ["parallel", "parallel", "parallel", "parallel"]}
            ins(%7, %8 : tensor<?x?x?x?xf32>, tensor<?x?x?x?xf32>) outs(%9 : tensor<?x?x?x?xf32>) attrs =  {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32, %arg2: f32):
          %11 = arith.addf %arg0, %arg1 : f32
          linalg.yield %11 : f32
        } -> tensor<?x?x?x?xf32>
        flow.dispatch.tensor.store %10, %6, offsets = [0, 0, 0, 0], sizes = [%0, %1, %2, %3], strides = [1, 1, 1, 1]
            : tensor<?x?x?x?xf32> -> !flow.dispatch.tensor<writeonly:?x?x?x?xf32>{%0, %1, %2, %3}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [64, 64, 64]>
//      CHECK: hal.executable.entry_point public @add4D
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-NEXT:   (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:    %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:    %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:    %[[D0:.+]] = affine.apply #[[MAP]]()[%[[ARG0]]]
//  CHECK-DAG:    %[[D1:.+]] = affine.apply #[[MAP]]()[%[[ARG1]]]
//  CHECK-DAG:    %[[D2:.+]] = affine.apply #[[MAP]]()[%[[ARG2]]]
//      CHECK:    hal.return %[[D0]], %[[D1]], %[[D2]] : index, index, index
//      CHECK: func @add4D()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       scf.for %[[IV2:.+]] =
//  CHECK-NOT:         scf.for
//      CHECK:         %[[GENERIC:.+]] = linalg.generic
//      CHECK:         flow.dispatch.tensor.store %[[GENERIC]], %{{.+}}, offsets = [0, %[[IV0]], %[[IV1]], %[[IV2]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[1, 64, 64, 0], [1, 16, 4, 64], [1, 4, 4, 4]], native_vector_size = [1, 4, 4, 4]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_arm_64_ = #hal.executable.target<"llvm", "embedded-elf-arm_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "aarch64-unknown-unknown-eabi-elf"}>
#translation = #iree_codegen.translation.info<"CPUTileFuseAndVectorize", workload_per_wg = []>
hal.executable private @batch_matmul_tensors {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_arm_64_ {
    hal.executable.entry_point public @batch_matmul_tensors layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @batch_matmul_tensors() {
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.constant.load[3] : index
        %4 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) alignment(32)
            : !flow.dispatch.tensor<readonly:?x?x?xf32>{%0, %1, %3}
        %5 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) alignment(32)
            : !flow.dispatch.tensor<readonly:?x?x?xf32>{%0, %3, %2}
        %6 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) alignment(32)
            : !flow.dispatch.tensor<writeonly:?x?x?xf32>{%0, %1, %2}
        %7 = flow.dispatch.tensor.load %4, offsets = [0, 0, 0], sizes = [%0, %1, %3], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:?x?x?xf32>{%0, %1, %3} -> tensor<?x?x?xf32>
        %8 = flow.dispatch.tensor.load %5, offsets = [0, 0, 0], sizes = [%0, %3, %2], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:?x?x?xf32>{%0, %3, %2} -> tensor<?x?x?xf32>
        %9 = linalg.init_tensor [%0, %1, %2] : tensor<?x?x?xf32>
        %10 = linalg.fill(%cst, %9) : f32, tensor<?x?x?xf32> -> tensor<?x?x?xf32>
        %11 = linalg.batch_matmul {lowering.config = #config}
            ins(%7, %8 : tensor<?x?x?xf32>, tensor<?x?x?xf32>) outs(%10 : tensor<?x?x?xf32>) -> tensor<?x?x?xf32>
        flow.dispatch.tensor.store %11, %6, offsets = [0, 0, 0], sizes = [%0, %1, %2], strides = [1, 1, 1]
            : tensor<?x?x?xf32> -> !flow.dispatch.tensor<writeonly:?x?x?xf32>{%0, %1, %2}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUTileFuseAndVectorize", workload_per_wg = [64, 64, 1]>
//      CHECK: hal.executable.entry_point public @batch_matmul_tensors
// CHECK-NEXT:   (%[[ARG0:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG1:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG2:[a-zA-Z0-9]+]]: index)
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP0]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[ARG2]]
//      CHECK: func @batch_matmul_tensors()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       scf.for %[[IV2:.+]] =
//  CHECK-NOT:         scf.for
//      CHECK:         %[[BATCH_GEMM:.+]] = linalg.batch_matmul
//      CHECK:         flow.dispatch.tensor.store %[[BATCH_GEMM]]
// CHECK-SAME:             offsets = [%[[IV0]], %[[IV1]], %[[IV2]]], sizes = [1, %{{.+}}, %{{.+}}]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[32, 16, 0], [16, 8, 0], [0, 0, 2]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64">
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @preset_config_matmul_tensors {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @preset_config layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @preset_config() {
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:128x256xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:256x512xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:128x512xf32>
        %3 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [128, 256], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:128x256xf32> -> tensor<128x256xf32>
        %4 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [256, 512], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:256x512xf32> -> tensor<256x512xf32>
        %5 = linalg.init_tensor [128, 512] : tensor<128x512xf32>
        %6 = linalg.fill(%cst, %5) : f32, tensor<128x512xf32> -> tensor<128x512xf32>
        %7 = linalg.matmul {lowering.config = #config}
            ins(%3, %4 : tensor<128x256xf32>, tensor<256x512xf32>) outs(%6 : tensor<128x512xf32>) -> tensor<128x512xf32>
        flow.dispatch.tensor.store %7, %2, offsets = [0, 0], sizes = [128, 512], strides = [1, 1]
            : tensor<128x512xf32> -> !flow.dispatch.tensor<writeonly:128x512xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 16)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 ceildiv 32)>
//  CHECK-DAG: #[[MAP2:.+]] = affine_map<()[s0] -> (s0 * 32)>
//  CHECK-DAG: #[[MAP3:.+]] = affine_map<()[s0] -> (s0 * 16)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [16, 32]>
//      CHECK: hal.executable.entry_point public @preset_config
// CHECK-NEXT:   (%[[ARG0:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG1:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG2:[a-zA-Z0-9]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP1]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[C1]]
//      CHECK: func @preset_config()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//  CHECK-DAG:       %[[LHS:.+]] = flow.dispatch.tensor.load %{{.+}}, offsets = [%[[IV0]], 0], sizes = [32, 256]
//  CHECK-DAG:       %[[RHS:.+]] = flow.dispatch.tensor.load %{{.+}}, offsets = [0, %[[IV1]]], sizes = [256, 16]
//  CHECK-DAG:       %[[INIT:.+]] = linalg.init_tensor [32, 16]
//  CHECK-DAG:       %[[FILL:.+]] = linalg.fill(%{{.+}}, %[[INIT]])
//  CHECK-DAG:       %[[GEMM:.+]] = linalg.matmul
// CHECK-SAME:           outs(%[[FILL]] :
//      CHECK:       flow.dispatch.tensor.store %[[GEMM]]
// CHECK-SAME:           offsets = [%[[IV0]], %[[IV1]]], sizes = [32, 16]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 64]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64">
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable public @tensor_insert {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @tensor_insert_slice layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @tensor_insert_slice() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.constant.load[3] : index
        %4 = hal.interface.constant.load[4] : index
        %5 = hal.interface.constant.load[5] : index
        %6 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xi32>{%0, %1}
        %7 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readwrite:?x?xi32>{%2, %3}
        %8 = flow.dispatch.tensor.load %6, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xi32>{%0, %1} -> tensor<?x?xi32>
        %9 = flow.dispatch.tensor.load %7, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readwrite:?x?xi32>{%2, %3} -> tensor<?x?xi32>
        %10 = tensor.insert_slice %8 into %9[%4, %5] [%0, %1] [1, 1] {lowering.config = #config} : tensor<?x?xi32> into tensor<?x?xi32>
        flow.dispatch.tensor.store %10, %7, offsets = [0, 0], sizes = [%2, %3], strides = [1, 1]
            : tensor<?x?xi32> -> !flow.dispatch.tensor<readwrite:?x?xi32>{%2, %3}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 * 64)>
//  CHECK-DAG: #[[MAP2:.+]] = affine_map<(d0)[s0] -> (64, -d0 + s0)>
//  CHECK-DAG: #[[MAP3:.+]] = affine_map<(d0)[s0] -> (d0 + s0)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [64, 64]>
//      CHECK: hal.executable.entry_point public @tensor_insert
// CHECK-SAME:     translation.info = #[[TRANSLATION]]
// CHECK-NEXT:   (%[[ARG0:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG1:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG2:[a-zA-Z0-9]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP0]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[C1]]
//      CHECK: func @tensor_insert_slice()
//  CHECK-DAG:   %[[SIZE_Y:.+]] = hal.interface.constant.load[0] : index
//  CHECK-DAG:   %[[SIZE_X:.+]] = hal.interface.constant.load[1] : index
//  CHECK-DAG:   %[[DEST_SIZE_Y:.+]] = hal.interface.constant.load[2] : index
//  CHECK-DAG:   %[[DEST_SIZE_X:.+]] = hal.interface.constant.load[3] : index
//  CHECK-DAG:   %[[OFFSET_Y:.+]] = hal.interface.constant.load[4] : index
//  CHECK-DAG:   %[[OFFSET_X:.+]] = hal.interface.constant.load[5] : index
//  CHECK-DAG:   %[[WG_ID_X:.+]] = hal.interface.workgroup.id[0]
//  CHECK-DAG:   %[[WG_COUNT_X:.+]] = hal.interface.workgroup.count[0]
//  CHECK-DAG:   %[[WG_ID_Y:.+]] = hal.interface.workgroup.id[1]
//  CHECK-DAG:   %[[WG_COUNT_Y:.+]] = hal.interface.workgroup.count[1]
//  CHECK-DAG:   %[[LB_Y:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_Y]]]
//  CHECK-DAG:   %[[STEP_Y:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_Y]]]
//      CHECK:   scf.for %[[IV0:.+]] = %[[LB_Y]] to %[[SIZE_Y]] step %[[STEP_Y]]
//  CHECK-DAG:     %[[TILESIZE_Y:.+]] = affine.min #[[MAP2]](%[[ARG0]])[%[[SIZE_Y]]]
//  CHECK-DAG:     %[[LB_X:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_X]]]
//  CHECK-DAG:     %[[STEP_X:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_X]]]
//      CHECK:     scf.for %[[IV1:.+]] = %[[LB_X]] to %[[SIZE_X]] step %[[STEP_X]]
//  CHECK-DAG:       %[[TILESIZE_X:.+]] = affine.min #[[MAP2]](%[[ARG1]])[%[[SIZE_X]]]
//  CHECK-DAG:       %[[SOURCE:.+]] = flow.dispatch.tensor.load
// CHECK-SAME:           offsets = [%[[IV0]], %[[IV1]]], sizes = [%[[TILESIZE_Y]], %[[TILESIZE_X]]]
//  CHECK-DAG:       %[[STORE_OFFSET_Y:.+]] = affine.apply #[[MAP3]](%[[IV0]])[%[[OFFSET_Y]]]
//  CHECK-DAG:       %[[STORE_OFFSET_X:.+]] = affine.apply #[[MAP3]](%[[IV1]])[%[[OFFSET_X]]]
//      CHECK:       flow.dispatch.tensor.store %[[SOURCE]]
// CHECK-SAME:           offsets = [%[[STORE_OFFSET_Y]], %[[STORE_OFFSET_X]]], sizes = [%[[TILESIZE_Y]], %[[TILESIZE_X]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 64]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64">
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable public @extract_slice {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @extract_slice layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @extract_slice() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.constant.load[3] : index
        %4 = hal.interface.constant.load[4] : index
        %5 = hal.interface.constant.load[5] : index
        %6 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xi32>{%0, %1}
        %7 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:?x?xi32>{%2, %3}
        %8 = flow.dispatch.tensor.load %6, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xi32>{%0, %1} -> tensor<?x?xi32>
        %9 = tensor.extract_slice %8[%4, %5] [%2, %3] [1, 1] {lowering.config = #config} : tensor<?x?xi32> to tensor<?x?xi32>
        flow.dispatch.tensor.store %9, %7, offsets = [0, 0], sizes = [%2, %3], strides = [1, 1]
            : tensor<?x?xi32> -> !flow.dispatch.tensor<writeonly:?x?xi32>{%2, %3}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 * 64)>
//  CHECK-DAG: #[[MAP2:.+]] = affine_map<(d0)[s0] -> (64, -d0 + s0)>
//  CHECK-DAG: #[[MAP3:.+]] = affine_map<(d0)[s0] -> (d0 + s0)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [64, 64]>
//      CHECK: hal.executable.entry_point public @extract_slice
// CHECK-SAME:     translation.info = #[[TRANSLATION]]
// CHECK-NEXT:   (%[[ARG0:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG1:[a-zA-Z0-9]+]]: index
// CHECK-SAME:    %[[ARG2:[a-zA-Z0-9]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP0]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[C1]]
//      CHECK: func @extract_slice()
//  CHECK-DAG:   %[[SOURCE_SIZE_Y:.+]] = hal.interface.constant.load[0] : index
//  CHECK-DAG:   %[[SOURCE_SIZE_X:.+]] = hal.interface.constant.load[1] : index
//  CHECK-DAG:   %[[SIZE_Y:.+]] = hal.interface.constant.load[2] : index
//  CHECK-DAG:   %[[SIZE_X:.+]] = hal.interface.constant.load[3] : index
//  CHECK-DAG:   %[[OFFSET_Y:.+]] = hal.interface.constant.load[4] : index
//  CHECK-DAG:   %[[OFFSET_X:.+]] = hal.interface.constant.load[5] : index
//  CHECK-DAG:   %[[WG_ID_X:.+]] = hal.interface.workgroup.id[0]
//  CHECK-DAG:   %[[WG_COUNT_X:.+]] = hal.interface.workgroup.count[0]
//  CHECK-DAG:   %[[WG_ID_Y:.+]] = hal.interface.workgroup.id[1]
//  CHECK-DAG:   %[[WG_COUNT_Y:.+]] = hal.interface.workgroup.count[1]
//  CHECK-DAG:   %[[LB_Y:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_Y]]]
//  CHECK-DAG:   %[[STEP_Y:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_Y]]]
//      CHECK:   scf.for %[[IV0:.+]] = %[[LB_Y]] to %[[SIZE_Y]] step %[[STEP_Y]]
//  CHECK-DAG:     %[[TILESIZE_Y:.+]] = affine.min #[[MAP2]](%[[ARG0]])[%[[SIZE_Y]]]
//  CHECK-DAG:     %[[LB_X:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_X]]]
//  CHECK-DAG:     %[[STEP_X:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_X]]]
//      CHECK:     scf.for %[[IV1:.+]] = %[[LB_X]] to %[[SIZE_X]] step %[[STEP_X]]
//  CHECK-DAG:       %[[TILESIZE_X:.+]] = affine.min #[[MAP2]](%[[ARG1]])[%[[SIZE_X]]]
//  CHECK-DAG:       %[[LOAD_OFFSET_Y:.+]] = affine.apply #[[MAP3]](%[[IV0]])[%[[OFFSET_Y]]]
//  CHECK-DAG:       %[[LOAD_OFFSET_X:.+]] = affine.apply #[[MAP3]](%[[IV1]])[%[[OFFSET_X]]]
//  CHECK-DAG:       %[[SOURCE:.+]] = flow.dispatch.tensor.load
// CHECK-SAME:           offsets = [%[[LOAD_OFFSET_Y]], %[[LOAD_OFFSET_X]]], sizes = [%[[TILESIZE_Y]], %[[TILESIZE_X]]]
//      CHECK:       flow.dispatch.tensor.store %[[SOURCE]]
// CHECK-SAME:           offsets = [%[[IV0]], %[[IV1]]], sizes = [%[[TILESIZE_Y]], %[[TILESIZE_X]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64">
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable private @static_1d_fft_stage2 {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @static_1d_fft_stage2 layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @static_1d_fft_stage2() {
        %c2 = arith.constant 2 : index
        %cst = arith.constant dense<[1.000000e+00, 6.12323426E-17]> : tensor<2xf32>
        %cst_0 = arith.constant dense<[-0.000000e+00, -1.000000e+00]> : tensor<2xf32>
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readwrite:32xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readwrite:32xf32>
        %2 = flow.dispatch.tensor.load %0, offsets = [0], sizes = [32], strides = [1]
            : !flow.dispatch.tensor<readwrite:32xf32> -> tensor<32xf32>
        %3 = flow.dispatch.tensor.load %1, offsets = [0], sizes = [32], strides = [1]
            : !flow.dispatch.tensor<readwrite:32xf32> -> tensor<32xf32>
        %4:2 = iree_linalg_ext.fft {__internal_linalg_transform__ = "workgroup", lowering.config = #config}
            ins(%c2, %cst, %cst_0 : index, tensor<2xf32>, tensor<2xf32>) outs(%2, %3 : tensor<32xf32>, tensor<32xf32>) : tensor<32xf32>, tensor<32xf32>
        flow.dispatch.tensor.store %4#0, %0, offsets = [0], sizes = [32], strides = [1]
            : tensor<32xf32> -> !flow.dispatch.tensor<readwrite:32xf32>
        flow.dispatch.tensor.store %4#1, %1, offsets = [0], sizes = [32], strides = [1]
            : tensor<32xf32> -> !flow.dispatch.tensor<readwrite:32xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [64]>
//      CHECK: hal.executable private @static_1d_fft_stage2
//      CHECK: hal.executable.entry_point public @static_1d_fft_stage2
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP]]()[%[[ARG0]]]
//      CHECK:   hal.return %[[D0]], %[[C1]], %[[C1]] : index, index, index
//      CHECK: func @static_1d_fft_stage2()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     %[[RESULT:.+]]:2 = iree_linalg_ext.fft
//  CHECK-DAG:     flow.dispatch.tensor.store %[[RESULT]]#0, %{{.+}}, offsets = [%[[IV0]]]
//  CHECK-DAG:     flow.dispatch.tensor.store %[[RESULT]]#1, %{{.+}}, offsets = [%[[IV0]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 64, 64]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64">
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable private @static_3d_fft_stage3 {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @static_3d_fft_stage3 layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @static_3d_fft_stage3() {
        %c3 = arith.constant 3 : index
        %cst = arith.constant dense<[1.000000e+00, 0.707106769, 6.12323426E-17, -0.707106769]> : tensor<4xf32>
        %cst_0 = arith.constant dense<[-0.000000e+00, -0.707106769, -1.000000e+00, -0.707106769]> : tensor<4xf32>
        %0 = bufferization.to_memref %cst_0 : memref<4xf32>
        %1 = bufferization.to_memref %cst : memref<4xf32>
        %2 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<64x128x32xf32>
        %3 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<64x128x32xf32>
        iree_linalg_ext.fft {lowering.config = #config}
            ins(%c3, %1, %0 : index, memref<4xf32>, memref<4xf32>) outs(%2, %3 : memref<64x128x32xf32>, memref<64x128x32xf32>)
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [64, 64, 64]>
//      CHECK: hal.executable private @static_3d_fft_stage3
//      CHECK: hal.executable.entry_point public @static_3d_fft_stage3
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP]]()[%[[ARG1]]]
//  CHECK-DAG:   %[[D2:.+]] = affine.apply #[[MAP]]()[%[[ARG2]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[D2]] : index, index, index
//      CHECK: func @static_3d_fft_stage3()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       scf.for %[[IV2:.+]] =
//  CHECK-DAG:         %[[SUBVIEW1:.+]] = memref.subview %{{.+}}[%[[IV0]], %[[IV1]], %[[IV2]]]
//  CHECK-DAG:         %[[SUBVIEW2:.+]] = memref.subview %{{.+}}[%[[IV0]], %[[IV1]], %[[IV2]]]
//      CHECK:         iree_linalg_ext.fft
// CHECK-SAME:             outs(%[[SUBVIEW1]], %[[SUBVIEW2]] :

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 64, 0], [1, 4, 0], [0, 0, 4]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64">
#map0 = affine_map<(d0, d1) -> (d0, d1)>
#map1 = affine_map<(d0, d1, d2) -> (d0, d2)>
#map2 = affine_map<(d0, d1, d2) -> (d2, d1)>
#map3 = affine_map<(d0, d1, d2) -> (d0, d1)>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @outs_fusion {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @outs_fusion_fn layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @outs_fusion_fn() {
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %2}
        %4 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%2, %1}
        %5 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:?x?xf32>{%0, %1}
        %6 = linalg.init_tensor [%0, %1] : tensor<?x?xf32>
        %7 = linalg.generic {
            indexing_maps = [#map0], iterator_types = ["parallel", "parallel"]} outs(%6 : tensor<?x?xf32>) {
        ^bb0(%arg0: f32):
          linalg.yield %cst : f32
        } -> tensor<?x?xf32>
        %8 = flow.dispatch.tensor.load %3, offsets = [0, 0], sizes = [%0, %2], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %2} -> tensor<?x?xf32>
        %9 = flow.dispatch.tensor.load %4, offsets = [0, 0], sizes = [%2, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%2, %1} -> tensor<?x?xf32>
        %10 = linalg.generic {
            indexing_maps = [#map1, #map2, #map3], iterator_types = ["parallel", "parallel", "reduction"]}
            ins(%8, %9 : tensor<?x?xf32>, tensor<?x?xf32>) outs(%7 : tensor<?x?xf32>) attrs =  {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32, %arg2: f32):
          %11 = arith.mulf %arg0, %arg1 : f32
          linalg.yield %11 : f32
        } -> tensor<?x?xf32>
        flow.dispatch.tensor.store %10, %5, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : tensor<?x?xf32> -> !flow.dispatch.tensor<writeonly:?x?xf32>{%0, %1}
        return
      }
    }
  }
}
//      CHECK: func @outs_fusion_fn
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       %[[INIT:.+]] = linalg.init_tensor
//      CHECK:       %[[FILL:.+]] = linalg.generic
// CHECK-SAME:           outs(%[[INIT]] :
//      CHECK:       %[[GENERIC:.+]] = linalg.generic
// CHECK-SAME:           outs(%[[FILL]] :
//      CHECK:       flow.dispatch.tensor.store %[[GENERIC]], %{{.+}}, offsets = [%[[IV0]], %[[IV1]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 64, 64, 64, 0, 0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"}>
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable private @conv {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @conv layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @conv() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.constant.load[3] : index
        %4 = hal.interface.constant.load[4] : index
        %5 = hal.interface.constant.load[5] : index
        %6 = hal.interface.constant.load[6] : index
        %7 = hal.interface.constant.load[7] : index
        %8 = hal.interface.constant.load[8] : index
        %9 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%0, %1, %2, %3}
        %10 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%4, %5, %3, %6}
        %11 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<readwrite:?x?x?x?xf32>{%0, %7, %8, %6}
        %12 = flow.dispatch.tensor.load %9, offsets = [0, 0, 0, 0], sizes = [%0, %1, %2, %3], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%0, %1, %2, %3} -> tensor<?x?x?x?xf32>
        %13 = flow.dispatch.tensor.load %10, offsets = [0, 0, 0, 0], sizes = [%4, %5, %3, %6], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:?x?x?x?xf32>{%4, %5, %3, %6} -> tensor<?x?x?x?xf32>
        %14 = flow.dispatch.tensor.load %11, offsets = [0, 0, 0, 0], sizes = [%0, %7, %8, %6], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readwrite:?x?x?x?xf32>{%0, %7, %8, %6} -> tensor<?x?x?x?xf32>
        %15 = linalg.conv_2d_nhwc_hwcf {dilations = dense<1> : tensor<2xi64>, lowering.config = #config, strides = dense<1> : tensor<2xi64>}
            ins(%12, %13 : tensor<?x?x?x?xf32>, tensor<?x?x?x?xf32>) outs(%14 : tensor<?x?x?x?xf32>) -> tensor<?x?x?x?xf32>
        flow.dispatch.tensor.store %15, %11, offsets = [0, 0, 0, 0], sizes = [%0, %7, %8, %6], strides = [1, 1, 1, 1]
            : tensor<?x?x?x?xf32> -> !flow.dispatch.tensor<readwrite:?x?x?x?xf32>{%0, %7, %8, %6}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [64, 64, 64]>
//      CHECK: hal.executable private @conv
//      CHECK: hal.executable.entry_point public @conv
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP]]()[%[[ARG1]]]
//  CHECK-DAG:   %[[D2:.+]] = affine.apply #[[MAP]]()[%[[ARG2]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[D2]] : index, index, index
//      CHECK: func @conv()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       scf.for %[[IV2:.+]] =
//  CHECK-DAG:         %[[INPUT:.+]] = flow.dispatch.tensor.load %{{.+}}, offsets = [0, %[[IV0]], %[[IV1]], 0]
//  CHECK-DAG:         %[[FILTER:.+]] = flow.dispatch.tensor.load %{{.+}}, offsets = [0, 0, 0, %[[IV2]]]
//  CHECK-DAG:         %[[INIT:.+]] = flow.dispatch.tensor.load %{{.+}}, offsets = [0, %[[IV0]], %[[IV1]], %[[IV2]]]
//      CHECK:         %[[RESULT:.+]] = linalg.conv_2d_nhwc_hwcf
//      CHECK:         flow.dispatch.tensor.store %[[RESULT]], %{{.+}}, offsets = [0, %[[IV0]], %[[IV1]], %[[IV2]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 20, 40, 48, 0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"}>
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable private @conv_static {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @conv_static layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @conv_static() {
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:1x161x161x96xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:3x3x96xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:1x80x80x96xf32>
        %3 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 161, 161, 96], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x161x161x96xf32> -> tensor<1x161x161x96xf32>
        %4 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0], sizes = [3, 3, 96], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:3x3x96xf32> -> tensor<3x3x96xf32>
        %5 = linalg.init_tensor [1, 80, 80, 96] : tensor<1x80x80x96xf32>
        %6 = linalg.fill(%cst, %5) : f32, tensor<1x80x80x96xf32> -> tensor<1x80x80x96xf32>
        %7 = linalg.depthwise_conv_2d_nhwc_hwc {dilations = dense<1> : tensor<2xi64>, lowering.config = #config, strides = dense<2> : tensor<2xi64>}
            ins(%3, %4 : tensor<1x161x161x96xf32>, tensor<3x3x96xf32>) outs(%6 : tensor<1x80x80x96xf32>) -> tensor<1x80x80x96xf32>
        flow.dispatch.tensor.store %7, %2, offsets = [0, 0, 0, 0], sizes = [1, 80, 80, 96], strides = [1, 1, 1, 1]
            : tensor<1x80x80x96xf32> -> !flow.dispatch.tensor<writeonly:1x80x80x96xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 48)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 ceildiv 40)>
//  CHECK-DAG: #[[MAP2:.+]] = affine_map<()[s0] -> (s0 ceildiv 20)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [48, 40, 20]>
//      CHECK: hal.executable private @conv_static
//      CHECK: hal.executable.entry_point public @conv_static
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP1]]()[%[[ARG1]]]
//  CHECK-DAG:   %[[D2:.+]] = affine.apply #[[MAP2]]()[%[[ARG2]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[D2]] : index, index, index
//      CHECK: func @conv_static()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       scf.for %[[IV2:.+]] =
//      CHECK:         %[[INIT:.+]] = linalg.init_tensor [1, 20, 40, 48]
//      CHECK:         %[[FILL:.+]] = linalg.fill(%{{.+}}, %[[INIT]])
//      CHECK:         %[[RESULT:.+]] = linalg.depthwise_conv_2d_nhwc_hwc
// CHECK-SAME:             outs(%[[FILL]] :
//      CHECK:         flow.dispatch.tensor.store %[[RESULT]], %{{.+}}, offsets = [0, %[[IV0]], %[[IV1]], %[[IV2]]], sizes = [1, 20, 40, 48]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[16, 32], [16, 16], [0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>
  ]>
]>
#executable_target_system_elf_x86_64_ = #hal.executable.target<"llvm", "system-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 64 : index,
  target_triple = "x86_64-pc-linux-gnu"}>
#map0 = affine_map<(d0, d1) -> (d1, d0)>
#map1 = affine_map<(d0, d1) -> (d0, d1)>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @generic_static {
  hal.executable.variant public @system_elf_x86_64, target = #executable_target_system_elf_x86_64_ {
    hal.executable.entry_point public @generic_static layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @generic_static() {
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:96x16xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:16x96xf32>
        %2 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [96, 16], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:96x16xf32> -> tensor<96x16xf32>
        %3 = linalg.init_tensor [16, 96] : tensor<16x96xf32>
        %4 = linalg.generic {
            indexing_maps = [#map0, #map1], iterator_types = ["parallel", "parallel"]}
            ins(%2 : tensor<96x16xf32>) outs(%3 : tensor<16x96xf32>) attrs =  {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32):
          linalg.yield %arg0 : f32
        } -> tensor<16x96xf32>
        flow.dispatch.tensor.store %4, %1, offsets = [0, 0], sizes = [16, 96], strides = [1, 1]
            : tensor<16x96xf32> -> !flow.dispatch.tensor<writeonly:16x96xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 32)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 ceildiv 16)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [32, 16]>
//      CHECK: hal.executable private @generic_static
//      CHECK: hal.executable.entry_point public @generic_static
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP1]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[C1]] : index, index, index
//      CHECK: func @generic_static()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       %[[RESULT:.+]] = linalg.generic
//      CHECK:       flow.dispatch.tensor.store %[[RESULT]], %{{.+}}, offsets = [%[[IV0]], %[[IV1]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[28, 8, 0], [4, 4, 60], [4, 4, 4]], native_vector_size = [4, 4, 4]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_system_elf_arm_64_ = #hal.executable.target<"llvm", "system-elf-arm_64", {
  data_layout = "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "aarch64-none-linux-android30"}>
#translation = #iree_codegen.translation.info<"CPUTileFuseAndVectorize", workload_per_wg = []>
hal.executable private @matmul_static {
  hal.executable.variant public @system_elf_arm_64, target = #executable_target_system_elf_arm_64_ {
    hal.executable.entry_point public @matmul_static layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @matmul_static() {
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:196x240xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:240x40xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:196x40xf32>
        %3 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [196, 240], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:196x240xf32> -> tensor<196x240xf32>
        %4 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [240, 40], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:240x40xf32> -> tensor<240x40xf32>
        %5 = linalg.init_tensor [196, 40] : tensor<196x40xf32>
        %6 = linalg.fill(%cst, %5) : f32, tensor<196x40xf32> -> tensor<196x40xf32>
        %7 = linalg.matmul {lowering.config = #config}
            ins(%3, %4 : tensor<196x240xf32>, tensor<240x40xf32>) outs(%6 : tensor<196x40xf32>) -> tensor<196x40xf32>
        flow.dispatch.tensor.store %7, %2, offsets = [0, 0], sizes = [196, 40], strides = [1, 1]
            : tensor<196x40xf32> -> !flow.dispatch.tensor<writeonly:196x40xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 8)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 ceildiv 28)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUTileFuseAndVectorize", workload_per_wg = [8, 28]>
//      CHECK: hal.executable private @matmul_static
//      CHECK: hal.executable.entry_point public @matmul_static
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP1]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[C1]] : index, index, index

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 1, 7, 64, 0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_system_elf_arm_64_ = #hal.executable.target<"llvm", "system-elf-arm_64", {
  data_layout = "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "aarch64-none-linux-android30"}>
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable private @restrict_num_workgroups {
  hal.executable.variant public @system_elf_arm_64, target = #executable_target_system_elf_arm_64_ {
    hal.executable.entry_point public @restrict_num_workgroups layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @restrict_num_workgroups() {
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:1x11x11x576xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:5x5x576xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:1x7x7x576xf32>
        %3 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 11, 11, 576], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x11x11x576xf32> -> tensor<1x11x11x576xf32>
        %4 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0], sizes = [5, 5, 576], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:5x5x576xf32> -> tensor<5x5x576xf32>
        %5 = linalg.init_tensor [1, 7, 7, 576] : tensor<1x7x7x576xf32>
        %6 = linalg.fill(%cst, %5) : f32, tensor<1x7x7x576xf32> -> tensor<1x7x7x576xf32>
        %7 = linalg.depthwise_conv_2d_nhwc_hwc {dilations = dense<1> : tensor<2xi64>, lowering.config = #config, strides = dense<1> : tensor<2xi64>}
            ins(%3, %4 : tensor<1x11x11x576xf32>, tensor<5x5x576xf32>) outs(%6 : tensor<1x7x7x576xf32>) -> tensor<1x7x7x576xf32>
        flow.dispatch.tensor.store %7, %2, offsets = [0, 0, 0, 0], sizes = [1, 7, 7, 576], strides = [1, 1, 1, 1]
            : tensor<1x7x7x576xf32> -> !flow.dispatch.tensor<writeonly:1x7x7x576xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 ceildiv 7)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [64, 7, 1]>
//      CHECK: hal.executable private @restrict_num_workgroups
//      CHECK: hal.executable.entry_point public @restrict_num_workgroups
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP1]]()[%[[ARG1]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[ARG2]] : index, index, index

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[4, 0, 0], [4, 0, 0], [0, 1, 4]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 4, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-unknown-eabi-elf"}>
#map0 = affine_map<(d0, d1, d2) -> (d0, d1, d2)>
#map1 = affine_map<(d0, d1, d2) -> (d0)>
#map2 = affine_map<(d0) -> (d0)>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @reduction {
  hal.executable.variant public @reduction, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @reduction ordinal(0) layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @reduction(%arg0 : !flow.dispatch.tensor<readonly:7x7x2048xf32>,
          %arg1 : !flow.dispatch.tensor<writeonly:7xf32>) {
        %cst = arith.constant 0.000000e+00 : f32
        %cst_0 = arith.constant 1.000000e+01 : f32
        %0 = flow.dispatch.tensor.load %arg0, offsets = [0, 0, 0], sizes = [7, 7, 2048], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:7x7x2048xf32> -> tensor<7x7x2048xf32>
        %1 = linalg.init_tensor [7] : tensor<7xf32>
        %2 = linalg.fill(%cst, %1) : f32, tensor<7xf32> -> tensor<7xf32>
        %3 = linalg.generic {
            indexing_maps = [#map0, #map1], iterator_types = ["parallel", "reduction", "reduction"]}
            ins(%0 : tensor<7x7x2048xf32>) outs(%2 : tensor<7xf32>) attrs =  {lowering.config = #config} {
        ^bb0(%arg2: f32, %arg3: f32):
          %5 = arith.addf %arg2, %arg3 : f32
          linalg.yield %5 : f32
        } -> tensor<7xf32>
        %4 = linalg.generic {
            indexing_maps = [#map2, #map2], iterator_types = ["parallel"]}
            ins(%3 : tensor<7xf32>) outs(%1 : tensor<7xf32>) {
        ^bb0(%arg2: f32, %arg3: f32):
          %5 = arith.divf %arg2, %cst_0 : f32
          linalg.yield %5 : f32
        } -> tensor<7xf32>
        flow.dispatch.tensor.store %4, %arg1, offsets = [0], sizes = [7], strides = [1]
            : tensor<7xf32> -> !flow.dispatch.tensor<writeonly:7xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 4)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [4]>
//      CHECK: hal.executable private @reduction
//      CHECK: hal.executable.entry_point public @reduction
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//      CHECK:   hal.return %[[D0]], %[[C1]], %[[C1]] : index, index, index
//      CHECK: func @reduction
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     %[[INIT0:.+]] = linalg.init_tensor
//      CHECK:     %[[INIT:.+]] = linalg.init_tensor
//      CHECK:     %[[FILL:.+]] = linalg.fill(%{{.+}}, %[[INIT]])
//      CHECK:     %[[REDUCE:.+]] = linalg.generic
// CHECK-SAME:         outs(%[[FILL]] :
//      CHECK:     %[[GENERIC:.+]] = linalg.generic
// CHECK-SAME:         ins(%[[REDUCE]] :
//      CHECK:     flow.dispatch.tensor.store %[[GENERIC]], %{{.+}}, offsets = [%[[IV0]]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[64, 0, 0], [8, 0, 0], [0, 0, 16]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 4, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-unknown-eabi-elf"}>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @gemm_unit_N {
  hal.executable.variant public @embedded_elf_x86_64, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @gemm_unit_N ordinal(0) layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @gemm_unit_N() {
        %c0 = arith.constant 0 : index
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) offset(%c0) alignment(32)
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %1}
        %3 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) offset(%c0) alignment(32)
            : !flow.dispatch.tensor<readonly:?x1xf32>{%1}
        %4 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) offset(%c0) alignment(32)
            : !flow.dispatch.tensor<readwrite:?x1xf32>{%0}
        %5 = flow.dispatch.tensor.load %3, offsets = [0, 0], sizes = [%1, 1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x1xf32>{%1} -> tensor<?x1xf32>
        %6 = flow.dispatch.tensor.load %2, offsets = [0, 0], sizes = [%0, %1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x?xf32>{%0, %1} -> tensor<?x?xf32>
        %7 = flow.dispatch.tensor.load %4, offsets = [0, 0], sizes = [%0, 1], strides = [1, 1]
            : !flow.dispatch.tensor<readwrite:?x1xf32>{%0} -> tensor<?x1xf32>
        %8 = linalg.matmul {lowering.config = #config}
            ins(%6, %5 : tensor<?x?xf32>, tensor<?x1xf32>) outs(%7 : tensor<?x1xf32>) -> tensor<?x1xf32>
        flow.dispatch.tensor.store %8, %4, offsets = [0, 0], sizes = [%0, 1], strides = [1, 1]
            : tensor<?x1xf32> -> !flow.dispatch.tensor<readwrite:?x1xf32>{%0}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 * 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [64]>
//      CHECK: hal.executable private @gemm_unit_N
//      CHECK: hal.executable.entry_point public @gemm_unit_N
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//      CHECK:   hal.return %[[D0]], %[[C1]], %[[C1]] : index, index, index
//      CHECK: func @gemm_unit_N()
//  CHECK-DAG:   %[[M:.+]] = hal.interface.constant.load[0]
//  CHECK-DAG:   %[[WG_ID_X:.+]] = hal.interface.workgroup.id[0]
//  CHECK-DAG:   %[[WG_COUNT_X:.+]] = hal.interface.workgroup.count[0]
//  CHECK-DAG:   %[[LB:.+]] = affine.apply #[[MAP1]]()[%[[WG_ID_X]]]
//  CHECK-DAG:   %[[STEP:.+]] = affine.apply #[[MAP1]]()[%[[WG_COUNT_X]]]
//      CHECK:   scf.for %[[IV0:.+]] = %[[LB]] to %[[M]] step %[[STEP]]
//  CHECK-NOT:     scf.for
//      CHECK:     %[[GEMM:.+]] = linalg.matmul
//      CHECK:     flow.dispatch.tensor.store %[[GEMM]],
// CHECK-SAME:         offsets = [%[[IV0]], 0]

// -----
#config = #iree_codegen.lowering.config<tile_sizes = [[0, 0, 0], [0, 0, 0], [0, 0, 16]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 4, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-unknown-eabi-elf"}>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @gemm_unit_M_unit_N {
  hal.executable.variant public @embedded_elf_x86_64, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @gemm_unit_M_unit_N ordinal(0) layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @gemm_unit_M_unit_N() {
        %c0 = arith.constant 0 : index
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) offset(%c0) alignment(32)
            : !flow.dispatch.tensor<readonly:1x?xf32>{%0}
        %2 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) offset(%c0) alignment(32)
            : !flow.dispatch.tensor<readonly:?x1xf32>{%0}
        %3 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) offset(%c0) alignment(32)
            : !flow.dispatch.tensor<readwrite:1x1xf32>
        %4 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [1, %0], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:1x?xf32>{%0} -> tensor<1x?xf32>
        %5 = flow.dispatch.tensor.load %2, offsets = [0, 0], sizes = [%0, 1], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:?x1xf32>{%0} -> tensor<?x1xf32>
        %6 = flow.dispatch.tensor.load %3, offsets = [0, 0], sizes = [1, 1], strides = [1, 1]
            : !flow.dispatch.tensor<readwrite:1x1xf32> -> tensor<1x1xf32>
        %7 = linalg.matmul {lowering.config = #config}
            ins(%4, %5 : tensor<1x?xf32>, tensor<?x1xf32>) outs(%6 : tensor<1x1xf32>) -> tensor<1x1xf32>
        flow.dispatch.tensor.store %7, %3, offsets = [0, 0], sizes = [1, 1], strides = [1, 1]
            : tensor<1x1xf32> -> !flow.dispatch.tensor<readwrite:1x1xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
//      CHECK: hal.executable private @gemm_unit_M_unit_N
//      CHECK: hal.executable.entry_point public @gemm_unit_M_unit_N
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//      CHECK:   hal.return %[[C1]], %[[C1]], %[[C1]] : index, index, index
//      CHECK: func @gemm_unit_M_unit_N()
//  CHECK-NOT:   scf.for
//      CHECK:   %[[GEMM:.+]] = linalg.matmul
//      CHECK:   flow.dispatch.tensor.store %[[GEMM]], %{{.+}}, offsets = [0, 0]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 0, 0, 0, 64, 64, 0, 64], [0, 1, 0, 0, 1, 1, 0, 4], [0, 0, 0, 0, 0, 0, 0, 0]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"}>
#map = affine_map<(d0, d1, d2, d3, d4, d5, d6, d7) -> (d0, d1, d2, d3, d4, d5, d6, d7)>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @generic_unit_dims {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @generic_unit_dims layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @generic_unit_dims() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.constant.load[1] : index
        %2 = hal.interface.constant.load[2] : index
        %3 = hal.interface.constant.load[3] : index
        %4 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:1x?x1x1x?x?x1x?xf32>{%0, %1, %2, %3}
        %5 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:1x?x1x1x?x?x1x?xf32>{%0, %1, %2, %3}
        %6 = flow.dispatch.tensor.load %4, offsets = [0, 0, 0, 0, 0, 0, 0, 0], sizes = [1, %0, 1, 1, %1, %2, 1, %3], strides = [1, 1, 1, 1, 1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x?x1x1x?x?x1x?xf32>{%0, %1, %2, %3} -> tensor<1x?x1x1x?x?x1x?xf32>
        %7 = linalg.init_tensor [1, %0, 1, 1, %1, %2, 1, %3] : tensor<1x?x1x1x?x?x1x?xf32>
        %8 = linalg.generic {
            indexing_maps = [#map, #map], iterator_types = ["parallel", "parallel", "parallel", "parallel", "parallel", "parallel", "parallel", "parallel"]}
            ins(%6 : tensor<1x?x1x1x?x?x1x?xf32>) outs(%7 : tensor<1x?x1x1x?x?x1x?xf32>) attrs =  {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32):
          %9 = arith.addf %arg0, %arg0 : f32
          linalg.yield %9 : f32
        } -> tensor<1x?x1x1x?x?x1x?xf32>
        flow.dispatch.tensor.store %8, %5, offsets = [0, 0, 0, 0, 0, 0, 0, 0], sizes = [1, %0, 1, 1, %1, %2, 1, %3], strides = [1, 1, 1, 1, 1, 1, 1, 1]
            : tensor<1x?x1x1x?x?x1x?xf32> -> !flow.dispatch.tensor<writeonly:1x?x1x1x?x?x1x?xf32>{%0, %1, %2, %3}
        return
      }
    }
  }
}
//  CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 ceildiv 64)>
//  CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 * 64)>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = [64, 64, 64]>
//      CHECK: hal.executable private @generic_unit_dims
//      CHECK: hal.executable.entry_point public @generic_unit_dims
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//  CHECK-DAG:   %[[D0:.+]] = affine.apply #[[MAP0]]()[%[[ARG0]]]
//  CHECK-DAG:   %[[D1:.+]] = affine.apply #[[MAP0]]()[%[[ARG1]]]
//  CHECK-DAG:   %[[D2:.+]] = affine.apply #[[MAP0]]()[%[[ARG2]]]
//      CHECK:   hal.return %[[D0]], %[[D1]], %[[D2]] : index, index, index
//      CHECK: func @generic_unit_dims()
//      CHECK:   scf.for %[[IV0:.+]] =
//      CHECK:     scf.for %[[IV1:.+]] =
//      CHECK:       scf.for %[[IV2:.+]] =
//      CHECK:         %[[GENERIC:.+]] = linalg.generic
//      CHECK:         flow.dispatch.tensor.store %[[GENERIC]],
// CHECK-SAME:             offsets = [0, 0, 0, 0, %[[IV0]], %[[IV1]], 0, %[[IV2]]]

// -----
#config = #iree_codegen.lowering.config<tile_sizes = [[0], [0], [4]], native_vector_size = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"}>
#map0 = affine_map<(d0) -> (d0)>
#map1 = affine_map<(d0) -> ()>
#translation = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
hal.executable private @reduce_to_scalar {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @reduce_to_scalar layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @reduce_to_scalar() {
        %0 = hal.interface.constant.load[0] : index
        %1 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:?xf32>{%0}
        %2 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<readwrite:f32>
        %3 = flow.dispatch.tensor.load %1, offsets = [0], sizes = [%0], strides = [1]
            : !flow.dispatch.tensor<readonly:?xf32>{%0} -> tensor<?xf32>
        %4 = flow.dispatch.tensor.load %2, offsets = [], sizes = [], strides = []
            : !flow.dispatch.tensor<readwrite:f32> -> tensor<f32>
        %5 = linalg.generic {
            indexing_maps = [#map0, #map1], iterator_types = ["reduction"]}
            ins(%3 : tensor<?xf32>) outs(%4 : tensor<f32>) attrs =  {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32):
          %6 = arith.addf %arg0, %arg1 : f32
          linalg.yield %6 : f32
        } -> tensor<f32>
        flow.dispatch.tensor.store %5, %2, offsets = [], sizes = [], strides = []
            : tensor<f32> -> !flow.dispatch.tensor<readwrite:f32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDoubleTilingExpert", workload_per_wg = []>
//      CHECK: hal.executable private @reduce_to_scalar
//      CHECK: hal.executable.entry_point public @reduce_to_scalar
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//      CHECK:   %[[C1:.+]] = arith.constant 1 : index
//      CHECK:   hal.return %[[C1]], %[[C1]], %[[C1]] : index, index, index
//      CHECK: func @reduce_to_scalar()
//  CHECK-NOT:   scf.for

// -----
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64", {
  data_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  native_vector_size = 16 : index,
  target_triple = "x86_64-unknown-linux-gnu"}>
#map = affine_map<() -> ()>
#translation = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
hal.executable private @scalar {
  hal.executable.variant public @llvm, target = #executable_target_embedded_elf_x86_64_ {
    hal.executable.entry_point public @scalar layout(#executable_layout) {translation.info = #translation}
    builtin.module {
      func @scalar() {
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
            : !flow.dispatch.tensor<readonly:f32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
            : !flow.dispatch.tensor<writeonly:f32>
        %2 = flow.dispatch.tensor.load %0, offsets = [], sizes = [], strides = []
            : !flow.dispatch.tensor<readonly:f32> -> tensor<f32>
        %3 = flow.dispatch.tensor.load %1, offsets = [], sizes = [], strides = []
            : !flow.dispatch.tensor<writeonly:f32> -> tensor<f32>
        %4 = linalg.generic {
            indexing_maps = [#map, #map], iterator_types = []}
            ins(%2 : tensor<f32>) outs(%3 : tensor<f32>) {
        ^bb0(%arg0: f32, %arg1: f32):
          %5 = arith.addf %arg0, %arg1 : f32
          linalg.yield %5 : f32
        } -> tensor<f32>
        flow.dispatch.tensor.store %4, %1, offsets = [], sizes = [], strides = []
            : tensor<f32> -> !flow.dispatch.tensor<writeonly:f32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = []>
//      CHECK: hal.executable private @scalar
//      CHECK: hal.executable.entry_point public @scalar
// CHECK-SAME:  translation.info = #[[TRANSLATION]]
// CHECK-NEXT:  (%[[ARG0:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG1:[a-zA-Z0-9_]+]]: index
// CHECK-SAME:   %[[ARG2:[a-zA-Z0-9_]+]]: index)
//      CHECK:   %[[C1:.+]] = arith.constant 1 : index
//      CHECK:   hal.return %[[C1]], %[[C1]], %[[C1]] : index, index, index
//      CHECK: func @scalar()
//  CHECK-NOT:   scf.for
