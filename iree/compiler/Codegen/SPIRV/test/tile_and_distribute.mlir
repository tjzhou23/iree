// RUN: iree-opt -split-input-file -pass-pipeline='hal.executable(hal.executable.variant(builtin.module(builtin.func(iree-spirv-tile-and-distribute))))' %s | FileCheck %s

#map0 = affine_map<()[s0] -> (s0 * 8)>
#map1 = affine_map<()[s0, s1] -> (8, s1 - s0 * 8)>
#map2 = affine_map<(d0)[s0] -> (4, -d0 + s0)>
#map3 = affine_map<(d0, d1)[s0, s1] -> (d0 * s1 + s0 + d1)>
#map4 = affine_map<(d0, d1, d2) -> (d0, d2)>
#map5 = affine_map<(d0, d1, d2) -> (d2, d1)>
#map6 = affine_map<(d0, d1, d2) -> (d0, d1)>

#config = #iree_codegen.lowering.config<tile_sizes = [[8, 16], [1, 1], [0, 0, 1]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"SPIRVDistribute", workload_per_wg = [8, 16]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable private @matmul {
  hal.executable.variant @vulkan, target = <"vulkan-spirv", "vulkan-spirv-fb"> {
    hal.executable.entry_point @matmul layout(#executable_layout) {
      workgroup_size = [16: index, 8: index, 1: index],
      translation.info = #translation
    }
    builtin.module {
      func @matmul() {
        %c0 = arith.constant 0 : index
        %M = hal.interface.constant.load[0] : index
        %N = hal.interface.constant.load[1] : index
        %K = hal.interface.constant.load[2] : index
        %arg0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<?x?xf32>{%M, %K}
        %arg1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<?x?xf32>{%K, %N}
        %arg2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<?x?xf32>{%M, %N}
        %c4 = arith.constant 4 : index
        %c1 = arith.constant 1 : index
        %0 = memref.dim %arg0, %c1 : memref<?x?xf32>
        %1 = gpu.block_id x
        %2 = gpu.block_id y
        scf.for %arg3 = %c0 to %0 step %c4 {
          %3 = affine.apply #map0()[%2]
          %4 = memref.dim %arg0, %c0 : memref<?x?xf32>
          %5 = affine.min #map1()[%2, %4]
          %6 = affine.min #map2(%arg3)[%0]
          %7 = memref.subview %arg0[%3, %arg3] [%5, %6] [1, 1]  : memref<?x?xf32> to memref<?x?xf32, #map3>
          %8 = memref.dim %arg1, %c0 : memref<?x?xf32>
          %9 = affine.min #map2(%arg3)[%8]
          %10 = affine.apply #map0()[%1]
          %11 = memref.dim %arg1, %c1 : memref<?x?xf32>
          %12 = affine.min #map1()[%1, %11]
          %13 = memref.subview %arg1[%arg3, %10] [%9, %12] [1, 1]  : memref<?x?xf32> to memref<?x?xf32, #map3>
          %14 = memref.dim %arg2, %c0 : memref<?x?xf32>
          %15 = affine.min #map1()[%2, %14]
          %16 = memref.dim %arg2, %c1 : memref<?x?xf32>
          %17 = affine.min #map1()[%1, %16]
          %18 = memref.subview %arg2[%3, %10] [%15, %17] [1, 1]  : memref<?x?xf32> to memref<?x?xf32, #map3>
          linalg.matmul {lowering.config = #config}
            ins(%7, %13 : memref<?x?xf32, #map3>, memref<?x?xf32, #map3>)
            outs(%18 : memref<?x?xf32, #map3>)
        }
        return
      }
    }
  }
}

// CHECK-LABEL: func @matmul
//   CHECK-DAG:   %[[C0:.+]] = arith.constant 0 : index
//   CHECK-DAG:   %[[C1:.+]] = arith.constant 1 : index
//   CHECK-DAG:   %[[TIDX:.+]] = gpu.thread_id x
//   CHECK-DAG:   %[[TIDY:.+]] = gpu.thread_id y
//   CHECK-DAG:   %[[BDIMX:.+]] = gpu.block_dim x
//   CHECK-DAG:   %[[BDIMY:.+]] = gpu.block_dim y
//       CHECK:     scf.for %{{.+}} = %[[TIDY]] to %{{.*}} step %[[BDIMY]]
//       CHECK:       scf.for %{{.+}} = %[[TIDX]] to %{{.*}} step %[[BDIMX]]
//       CHECK:         scf.for %{{.+}} = %[[C0]] to %{{.*}} step %[[C1]]
//       CHECK:           linalg.matmul

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[1, 4, 32], [1, 1, 1]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"SPIRVDistribute", workload_per_wg = [32, 4, 1]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable private @conv_1d {
  hal.executable.variant @vulkan, target = <"vulkan-spirv", "vulkan-spirv-fb"> {
    hal.executable.entry_point @conv_1d layout(#executable_layout) {
      workgroup_size = [32: index, 4: index, 1: index],
      translation.info = #translation
    }
    builtin.module {
      func @conv_1d() {
        %cst = arith.constant 0.000000e+00 : f32
        %c0 = arith.constant 0 : index
        %0 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<3x6x1xf32>
        %1 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<3x8x1xf32>
        %2 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<3x1x1xf32>
        %3 = gpu.block_id x
        %4 = gpu.block_id y
        %5 = gpu.block_id z 
        %6 = affine.apply affine_map<()[s0] -> (s0 * 4)>()[%4]
        %7 = affine.min affine_map<()[s0] -> (6, s0 * -4 + 8)>()[%4]
        %8 = memref.subview %1[%5, %6, 0] [1, %7, 1] [1, 1, 1] : memref<3x8x1xf32> to memref<1x?x1xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 8 + s0 + d1 + d2)>>
        %9 = affine.apply affine_map<()[s0] -> (s0 * 32)>()[%3]
        %10 = affine.min affine_map<()[s0] -> (32, s0 * -32 + 1)>()[%3]
        %11 = memref.subview %2[0, 0, %9] [3, 1, %10] [1, 1, 1] : memref<3x1x1xf32> to memref<3x1x?xf32, affine_map<(d0, d1, d2)[s0] -> (d0 + s0 + d1 + d2)>>
        %12 = affine.apply affine_map<()[s0] -> (s0 * 4)>()[%4]
        %13 = affine.min affine_map<()[s0] -> (4, s0 * -4 + 6)>()[%4]
        %14 = affine.apply affine_map<()[s0] -> (s0 * 32)>()[%3]
        %15 = affine.min affine_map<()[s0] -> (32, s0 * -32 + 1)>()[%3]
        %16 = memref.subview %0[%5, %12, %14] [1, %13, %15] [1, 1, 1] : memref<3x6x1xf32> to memref<1x?x?xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 6 + s0 + d1 + d2)>>
        %17 = memref.subview %0[%5, %12, %9] [1, %13, %10] [1, 1, 1] : memref<3x6x1xf32> to memref<1x?x?xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 6 + s0 + d1 + d2)>>
        linalg.conv_1d_nwc_wcf {lowering.config = #config, dilations = dense<1> : tensor<1xi64>, strides = dense<1> : tensor<1xi64>}
          ins(%8, %11 : memref<1x?x1xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 8 + s0 + d1 + d2)>>, memref<3x1x?xf32, affine_map<(d0, d1, d2)[s0] -> (d0 + s0 + d1 + d2)>>)
          outs(%16 : memref<1x?x?xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 6 + s0 + d1 + d2)>>)
        return
      }
    }
  }
}

// CHECK-LABEL: func @conv_1d
//       CHECK-DAG: %[[RET:.+]] = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
//       CHECK-DAG: %[[ARG0:.+]] = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
//       CHECK-DAG: %[[ARG1:.+]] = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
//       CHECK-DAG: %[[ARG0SV1:.+]] = memref.subview %[[ARG0]]
//       CHECK-DAG: %[[ARG1SV1:.+]] = memref.subview %[[ARG1]]
//       CHECK-DAG: %[[RETSV1:.+]] = memref.subview %[[RET]]
//       CHECK: %[[TIDX:.+]] = gpu.thread_id x
//       CHECK: %[[BDIMX:.+]] = gpu.block_dim x
//       CHECK: %[[TIDY:.+]] = gpu.thread_id y
//       CHECK: %[[BDIMY:.+]] = gpu.block_dim y
//       CHECK: %[[TIDZ:.+]] = gpu.thread_id z
//       CHECK: %[[BDIMZ:.+]] = gpu.block_dim z
//       CHECK: scf.for %[[IV_Z:.+]] = %[[TIDZ]] to %{{.*}} step %[[BDIMZ]]
//       CHECK:   scf.for %[[IV_Y:.+]] = %[[TIDY]] to %{{.*}} step %[[BDIMY]]
//       CHECK:     scf.for %[[IV_X:.+]] = %[[TIDX]] to %{{.*}} step %[[BDIMX]]
//       CHECK:       %[[ARG0SV2:.+]] = memref.subview %[[ARG0SV1]][%[[IV_Z]], %[[IV_Y]], 0] [1, 3, 1]
//       CHECK:       %[[ARG1SV2:.+]] = memref.subview %[[ARG1SV1]][0, 0, %[[IV_X]]] [3, 1, 1]
//       CHECK:       %[[RETSV2:.+]] = memref.subview %[[RETSV1]][%[[IV_Z]], %[[IV_Y]], %[[IV_X]]] [1, 1, 1]
//       CHECK:       linalg.conv_1d_nwc_wcf
//  CHECK-SAME:         ins(%[[ARG0SV2]], %[[ARG1SV2]]
//  CHECK-SAME:         outs(%[[RETSV2]]

// -----

#map0 = affine_map<()[s0] -> (s0 * 4)>
#map1 = affine_map<()[s0] -> (s0 * 32)>
#map2 = affine_map<(d0)[s0] -> (1, -d0 + s0)>
#map3 = affine_map<(d0)[s0, s1] -> (s0 + 4, -d0 + s1)>
#map4 = affine_map<(d0)[s0, s1] -> (s0 + 32, -d0 + s1)>
#map5 = affine_map<(d0, d1, d2, d3)[s0, s1, s2, s3] -> (d0 * s1 + s0 + d1 * s2 + d2 * s3 + d3)>
#map6 = affine_map<(d0)[s0] -> (4, -d0 + s0)>
#map7 = affine_map<(d0)[s0] -> (32, -d0 + s0)>

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 1, 4, 32], [0, 1, 1, 1], [0, 0, 0, 0, 1, 1, 4]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"SPIRVDistribute", workload_per_wg = [32, 4, 1]>
#executable_layout = #hal.executable.layout<push_constants = 9, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable private @conv_2d {
  hal.executable.variant @vulkan, target = <"vulkan-spirv", "vulkan-spirv-fb"> {
    hal.executable.entry_point @conv_2d layout(#executable_layout) {
      workgroup_size = [32: index, 4: index, 1: index],
      translation.info = #translation
    }
    builtin.module {
      func @conv_2d() {
        %c0 = arith.constant 0 : index
        %n = hal.interface.constant.load[0] : index
        %oh = hal.interface.constant.load[1] : index
        %ow = hal.interface.constant.load[2] : index
        %oc = hal.interface.constant.load[3] : index
        %ih = hal.interface.constant.load[4] : index
        %iw = hal.interface.constant.load[5] : index
        %ic = hal.interface.constant.load[6] : index
        %fh = hal.interface.constant.load[7] : index
        %fw = hal.interface.constant.load[8] : index
        %arg0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<?x?x?x?xf32>{%n, %ih, %iw, %ic}
        %arg1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<?x?x?x?xf32>{%fh, %fw, %ic, %oc}
        %arg2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<?x?x?x?xf32>{%n, %oh, %ow, %oc}
        %c2 = arith.constant 2 : index
        %c3 = arith.constant 3 : index
        %c1 = arith.constant 1 : index
        %0 = memref.dim %arg0, %c0 : memref<?x?x?x?xf32>
        %1 = memref.dim %arg0, %c1 : memref<?x?x?x?xf32>
        %2 = memref.dim %arg1, %c0 : memref<?x?x?x?xf32>
        %3 = memref.dim %arg2, %c1 : memref<?x?x?x?xf32>
        %4 = memref.dim %arg2, %c2 : memref<?x?x?x?xf32>
        %5 = gpu.block_id x
        %6 = gpu.grid_dim x
        %7 = gpu.block_id y
        %8 = gpu.grid_dim y
        %9 = gpu.block_id z 
        %10 = gpu.grid_dim z
        %11 = affine.apply #map0()[%7]
        %12 = affine.apply #map0()[%8]
        %13 = affine.apply #map1()[%5]
        %14 = affine.apply #map1()[%6]
        scf.for %arg3 = %9 to %2 step %10 {
          scf.for %arg4 = %11 to %3 step %12 {
            scf.for %arg5 = %13 to %4 step %14 {
              %15 = affine.min #map2(%arg3)[%2]
              %16 = memref.dim %arg1, %c1 : memref<?x?x?x?xf32>
              %17 = affine.min #map3(%arg4)[%0, %16]
              %18 = memref.dim %arg1, %c2 : memref<?x?x?x?xf32>
              %19 = affine.min #map4(%arg5)[%1, %18]
              %20 = memref.dim %arg1, %c3 : memref<?x?x?x?xf32>
              %21 = memref.subview %arg1[%arg3, %arg4, %arg5, 0] [%15, %17, %19, %20] [1, 1, 1, 1]
                      : memref<?x?x?x?xf32> to memref<?x?x?x?xf32, #map5>
              %22 = memref.dim %arg2, %c0 : memref<?x?x?x?xf32>
              %23 = affine.min #map2(%arg3)[%22]
              %24 = affine.min #map6(%arg4)[%3]
              %25 = affine.min #map7(%arg5)[%4]
              %26 = memref.dim %arg2, %c3 : memref<?x?x?x?xf32>
              %27 = memref.subview %arg2[%arg3, %arg4, %arg5, 0] [%23, %24, %25, %26] [1, 1, 1, 1]
                      : memref<?x?x?x?xf32> to memref<?x?x?x?xf32, #map5>
              linalg.conv_2d_nhwc_hwcf {
                lowering.config = #config,
                dilations = dense<1> : tensor<2xi64>,
                strides = dense<2> : tensor<2xi64>}
                 ins(%21, %arg0 : memref<?x?x?x?xf32, #map5>, memref<?x?x?x?xf32>)
                outs(%27 : memref<?x?x?x?xf32, #map5>)
            }
          }
        }
        return
      }
    }
  }
}

//     CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 * 4)>
//     CHECK-DAG: #[[MAP1:.+]] = affine_map<()[s0] -> (s0 * 32)>
//         CHECK: func @conv_2d
//     CHECK-DAG:   %[[ARG0:.+]] = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
//     CHECK-DAG:   %[[ARG1:.+]] = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
//     CHECK-DAG:   %[[RET0:.+]] = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
//     CHECK-DAG:   %[[C0:.+]] = arith.constant 0
//     CHECK-DAG:   %[[C1:.+]] = arith.constant 1
//     CHECK-DAG:   %[[C4:.+]] = arith.constant 4
//         CHECK:   %[[INPUT_BLOCK:.+]] = memref.subview %[[ARG1]]
//         CHECK:   %[[OUTPUT_BLOCK:.+]] = memref.subview %[[RET0]]
//     CHECK-DAG:   %[[TIDX:.+]] = gpu.thread_id x
//     CHECK-DAG:   %[[TIDY:.+]] = gpu.thread_id y
//     CHECK-DAG:   %[[TIDZ:.+]] = gpu.thread_id z
//     CHECK-DAG:   %[[BDIMX:.+]] = gpu.block_dim x
//     CHECK-DAG:   %[[BDIMY:.+]] = gpu.block_dim y
//     CHECK-DAG:   %[[BDIMZ:.+]] = gpu.block_dim z
//         CHECK:   scf.for %[[IV_Z:.+]] = %[[TIDZ]] to %{{.*}} step %[[BDIMZ]]
//         CHECK:     scf.for %[[IV_Y:.+]] = %[[TIDY]] to %{{.*}} step %[[BDIMY]]
//         CHECK:       scf.for %[[IV_X:.+]] = %[[TIDX]] to %{{.*}} step %[[BDIMX]]
//         CHECK:         %[[INPUT_THREAD:.+]] = memref.subview %[[INPUT_BLOCK]]
//         CHECK:         %[[FILTER_THREAD:.+]] = memref.subview %[[ARG0]]
//         CHECK:         %[[OUTPUT:.+]] = memref.subview %[[OUTPUT_BLOCK]][0, %[[IV_Z]], %[[IV_Y]], %[[IV_X]]]
//         CHECK:         scf.for %[[IV_FH:.+]] = %[[C0]] to %{{.+}} step %[[C1]]
//         CHECK:           scf.for %[[IV_FW:.+]] = %[[C0]] to %{{.+}} step %[[C1]]
//         CHECK:             scf.for %[[IV_IC:.+]] = %[[C0]] to %{{.+}} step %[[C4]]
//         CHECK:               %[[INPUT:.+]] = memref.subview %[[INPUT_THREAD]]
//         CHECK:               %[[FILTER:.+]] = memref.subview %[[FILTER_THREAD]]
//         CHECK:               linalg.conv_2d_nhwc_hwcf
//    CHECK-SAME:                 ins(%[[INPUT]], %[[FILTER]]
//    CHECK-SAME:                 outs(%[[OUTPUT]]

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[0, 0, 1, 4, 32], [0, 0, 1, 1, 1]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"SPIRVDistribute", workload_per_wg = [32, 4, 1]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable private @conv_3d {
  hal.executable.variant @vulkan, target = <"vulkan-spirv", "vulkan-spirv-fb"> {
    hal.executable.entry_point @conv_3d layout(#executable_layout) {
      workgroup_size = [32: index, 4: index, 1: index],
      translation.info = #translation
    }
    builtin.module {
      func @conv_3d() {
        %cst = arith.constant 0.000000e+00 : f32
        %c0 = arith.constant 0 : index
        %0 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<2x7x7x7x2xf32>
        %1 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<2x8x8x8x3xf32>
        %2 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<2x2x2x3x2xf32>
        %3 = gpu.block_id x
        %4 = gpu.block_id y
        %5 = gpu.block_id z 
        %6 = affine.apply affine_map<()[s0] -> (s0 * 4)>()[%4]
        %7 = affine.min affine_map<()[s0] -> (5, s0 * -4 + 8)>()[%4]
        %8 = affine.apply affine_map<()[s0] -> (s0 * 32)>()[%3]
        %9 = affine.min affine_map<()[s0] -> (33, s0 * -32 + 8)>()[%3]
        %10 = memref.subview %1[%5, %6, %8, 0, 0] [1, %7, %9, 8, 3] [1, 1, 1, 1, 1] : memref<2x8x8x8x3xf32> to memref<1x?x?x8x3xf32, affine_map<(d0, d1, d2, d3, d4)[s0] -> (d0 * 1536 + s0 + d1 * 192 + d2 * 24 + d3 * 3 + d4)>>
        %11 = affine.apply affine_map<()[s0] -> (s0 * 4)>()[%4]
        %12 = affine.min affine_map<()[s0] -> (4, s0 * -4 + 7)>()[%4]
        %13 = affine.apply affine_map<()[s0] -> (s0 * 32)>()[%3]
        %14 = affine.min affine_map<()[s0] -> (32, s0 * -32 + 7)>()[%3]
        %15 = memref.subview %0[%5, %11, %13, 0, 0] [1, %12, %14, 7, 2] [1, 1, 1, 1, 1] : memref<2x7x7x7x2xf32> to memref<1x?x?x7x2xf32, affine_map<(d0, d1, d2, d3, d4)[s0] -> (d0 * 686 + s0 + d1 * 98 + d2 * 14 + d3 * 2 + d4)>>
        %16 = memref.subview %0[%5, %11, %13, 0, 0] [1, %12, %14, 7, 2] [1, 1, 1, 1, 1] : memref<2x7x7x7x2xf32> to memref<1x?x?x7x2xf32, affine_map<(d0, d1, d2, d3, d4)[s0] -> (d0 * 686 + s0 + d1 * 98 + d2 * 14 + d3 * 2 + d4)>>
        linalg.conv_3d_ndhwc_dhwcf {lowering.config = #config, dilations = dense<1> : tensor<3xi64>, strides = dense<1> : tensor<3xi64>}
          ins(%10, %2 : memref<1x?x?x8x3xf32, affine_map<(d0, d1, d2, d3, d4)[s0] -> (d0 * 1536 + s0 + d1 * 192 + d2 * 24 + d3 * 3 + d4)>>, memref<2x2x2x3x2xf32>)
          outs(%15 : memref<1x?x?x7x2xf32, affine_map<(d0, d1, d2, d3, d4)[s0] -> (d0 * 686 + s0 + d1 * 98 + d2 * 14 + d3 * 2 + d4)>>)
        return
      }
    }
  }
}

//   CHECK-LABEL: func @conv_3d
//     CHECK-DAG:   %[[TIDX:.+]] = gpu.thread_id x
//     CHECK-DAG:   %[[TIDY:.+]] = gpu.thread_id y
//     CHECK-DAG:   %[[TIDZ:.+]] = gpu.thread_id z
//     CHECK-DAG:   %[[BDIMX:.+]] = gpu.block_dim x
//     CHECK-DAG:   %[[BDIMY:.+]] = gpu.block_dim y
//     CHECK-DAG:   %[[BDIMZ:.+]] = gpu.block_dim z
//         CHECK:   scf.for %[[IV0:.+]] = %[[TIDZ]] to %{{.*}} step %[[BDIMZ]]
//         CHECK:     scf.for %[[IV1:.+]] = %[[TIDY]] to %{{.*}} step %[[BDIMY]]
//         CHECK:       scf.for %[[IV2:.+]] = %[[TIDX]] to %{{.*}} step %[[BDIMX]]
//         CHECK:         %[[OUT:.+]] = memref.subview %{{.+}}[0, 0, %[[IV0]], %[[IV1]], %[[IV2]]]
//         CHECK:         linalg.conv_3d_ndhwc_dhwcf
//    CHECK-SAME:           outs(%[[OUT]]

// -----

#map0 = affine_map<()[s0] -> (s0 * 4)>
#map1 = affine_map<()[s0] -> (6, s0 * -4 + 16)>
#map2 = affine_map<()[s0] -> (s0 * 32)>
#map3 = affine_map<()[s0] -> (35, s0 * -32 + 16)>
#map4 = affine_map<(d0, d1, d2, d3)[s0] -> (d0 * 1536 + s0 + d1 * 96 + d2 * 6 + d3)>
#map5 = affine_map<()[s0] -> (4, s0 * -4 + 14)>
#map6 = affine_map<()[s0] -> (32, s0 * -32 + 13)>
#map7 = affine_map<(d0, d1, d2, d3)[s0] -> (d0 * 1092 + s0 + d1 * 78 + d2 * 6 + d3)>

#config = #iree_codegen.lowering.config<tile_sizes = [[1, 4, 32], [1, 1, 1]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"SPIRVDistribute", workload_per_wg = [32, 4, 1]>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
module  {
  hal.executable private @pooling_nhwc_max {
    hal.executable.variant @vulkan, target = <"vulkan-spirv", "vulkan-spirv-fb"> {
      hal.executable.entry_point @pooling_nhwc_max layout(#executable_layout) {
        workgroup_size = [32: index, 4: index, 1: index],
        translation.info = #translation
      }
      builtin.module {
        func @pooling_nhwc_max() {
          %c0 = arith.constant 0 : index
          %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<2x16x16x6xf32>
          %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<3x4xf32>
          %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<2x14x13x6xf32>
          %3 = gpu.block_id x
          %4 = gpu.block_id y
          %5 = affine.apply #map0()[%4]
          %6 = affine.min #map1()[%4]
          %7 = affine.apply #map2()[%3]
          %8 = affine.min #map3()[%3]
          %9 = memref.subview %0[0, %5, %7, 0] [2, %6, %8, 6] [1, 1, 1, 1] : memref<2x16x16x6xf32> to memref<2x?x?x6xf32, #map4>
          %10 = affine.min #map5()[%4]
          %11 = affine.min #map6()[%3]
          %12 = memref.subview %2[0, %5, %7, 0] [2, %10, %11, 6] [1, 1, 1, 1] : memref<2x14x13x6xf32> to memref<2x?x?x6xf32, #map7>
          linalg.pooling_nhwc_max {lowering.config = #config, dilations = dense<1> : vector<2xi64>, strides = dense<1> : vector<2xi64>}
            ins(%9, %1 : memref<2x?x?x6xf32, #map4>, memref<3x4xf32>)
            outs(%12 : memref<2x?x?x6xf32, #map7>)
          return
        }
      }
    }
  }
}

//     CHECK-DAG: #[[MAP0:.+]] = affine_map<()[s0] -> (s0 * 4)>
//     CHECK-DAG: #[[MAP2:.+]] = affine_map<()[s0] -> (s0 * 32)>
//         CHECK: func @pooling_nhwc_max
//     CHECK-DAG:   %[[ARG0:.+]] = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer)
//     CHECK-DAG:   %[[ARG1:.+]] = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer)
//     CHECK-DAG:   %[[RET0:.+]] = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer)
//         CHECK:   %[[SV1:.+]] = memref.subview %[[ARG0]]
//         CHECK:   %[[SV2:.+]] = memref.subview %[[RET0]]
//     CHECK-DAG:   %[[TIDX:.+]] = gpu.thread_id x
//     CHECK-DAG:   %[[TIDY:.+]] = gpu.thread_id y
//     CHECK-DAG:   %[[TIDZ:.+]] = gpu.thread_id z
//     CHECK-DAG:   %[[BDIMX:.+]] = gpu.block_dim x
//     CHECK-DAG:   %[[BDIMY:.+]] = gpu.block_dim y
//     CHECK-DAG:   %[[BDIMZ:.+]] = gpu.block_dim z
//         CHECK:   scf.for %[[IV0:.+]] = %[[TIDZ]] to %{{.*}} step %[[BDIMZ]]
//         CHECK:     scf.for %[[IV1:.+]] = %[[TIDY]] to %{{.*}} step %[[BDIMY]]
//         CHECK:       scf.for %[[IV2:.+]] = %[[TIDX]] to %{{.*}} step %[[BDIMX]]
//         CHECK:         %[[IN:.+]] = memref.subview %[[SV1]][%[[IV0]], %[[IV1]], %[[IV2]], 0] [1, 3, 4, 6]
//         CHECK:         %[[OUT:.+]] = memref.subview %[[SV2]][%[[IV0]], %[[IV1]], %[[IV2]], 0] [1, 1, 1, 6]
//         CHECK:         linalg.pooling_nhwc_max
//    CHECK-SAME:           ins(%[[IN]], %[[ARG1]]
//    CHECK-SAME:           outs(%[[OUT]]
