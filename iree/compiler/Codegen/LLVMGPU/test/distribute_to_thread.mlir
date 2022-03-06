// RUN: iree-opt -split-input-file -pass-pipeline='hal.executable(hal.executable.variant(builtin.module(builtin.func(iree-llvmgpu-tile-and-distribute))))' %s | FileCheck %s

#config = #iree_codegen.lowering.config<tile_sizes = [[2, 256, 4]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"LLVMGPUMatmulSimt", workload_per_wg = [256, 2]>
#executable_target_cuda_nvptx_fb = #hal.executable.target<"cuda", "cuda-nvptx-fb">
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#map0 = affine_map<()[s0] -> (s0 * 2)>
#map1 = affine_map<()[s0] -> (s0 * 256)>
#map2 = affine_map<(d0) -> (2, -d0 + 1024)>
#map3 = affine_map<(d0) -> (256, -d0 + 1024)>
#map4 = affine_map<(d0, d1)[s0] -> (d0 * 1024 + s0 + d1)>
hal.executable private @dot_dispatch_0  {
  hal.executable.variant @cuda, target = #executable_target_cuda_nvptx_fb {
    hal.executable.entry_point @dot_dispatch_0 layout(#executable_layout) {
      translation.info = #translation,
      workgroup_size = [64 : index, 1 : index, 1 : index]
    }
    builtin.module {
      builtin.func @dot_dispatch_0() {
        %cst = arith.constant 0.000000e+00 : f32
        %c0 = arith.constant 0 : index
        %c1024 = arith.constant 1024 : index
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<1024x1024xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<1024x1024xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<1024x1024xf32>
        %workgroup_size_x = hal.interface.workgroup.size[0] : index
        %workgroup_size_y = hal.interface.workgroup.size[1] : index
        %workgroup_id_x = hal.interface.workgroup.id[0] : index
        %workgroup_count_x = hal.interface.workgroup.count[0] : index
        %workgroup_id_y = hal.interface.workgroup.id[1] : index
        %workgroup_count_y = hal.interface.workgroup.count[1] : index
        %3 = affine.apply #map0()[%workgroup_id_y]
        %4 = affine.apply #map0()[%workgroup_count_y]
        scf.for %arg0 = %3 to %c1024 step %4 {
          %5 = affine.apply #map1()[%workgroup_id_x]
          %6 = affine.apply #map1()[%workgroup_count_x]
          scf.for %arg1 = %5 to %c1024 step %6 {
            %8 = memref.subview %0[%arg0, 0] [2, 1024] [1, 1]
                : memref<1024x1024xf32> to memref<2x1024xf32, #map4>
            %10 = memref.subview %1[0, %arg1] [1024, 256] [1, 1]
                : memref<1024x1024xf32> to memref<1024x256xf32, #map4>
            %11 = memref.subview %2[%arg0, %arg1] [2, 256] [1, 1]
                : memref<1024x1024xf32> to memref<2x256xf32, #map4>
            linalg.fill(%cst, %11) {lowering.config = #config}
                : f32, memref<2x256xf32, #map4>
            linalg.matmul {lowering.config = #config}
                ins(%8, %10 : memref<2x1024xf32, #map4>, memref<1024x256xf32, #map4>)
                outs(%11 : memref<2x256xf32, #map4>)
          }
        }
        return
      }
    }
  }
}

//   CHECK-LABEL: hal.executable private @dot_dispatch_0
//         CHECK:   hal.executable.variant public @cuda
//     CHECK-DAG:  %[[C0:.+]] = arith.constant 0 : index
//     CHECK-DAG:  %[[C2:.+]] = arith.constant 2 : index
//     CHECK-DAG:  %[[C4:.+]] = arith.constant 4 : index
//     CHECK-DAG:  %[[C256:.+]] = arith.constant 256 : index
//     CHECK-DAG:  %[[C1024:.+]] = arith.constant 1024 : index
//     CHECK-DAG:  %[[BUFFER0:.+]] = memref.alloc() : memref<4x256xf32, 3>
//     CHECK-DAG:  %[[BUFFER1:.+]] = memref.alloc() : memref<2x4xf32, 3>
//         CHECK:  scf.for %[[K:.+]] = %[[C0]] to %[[C1024]] step %[[C4]] {
//         CHECK:    gpu.barrier
//         CHECK:    linalg.generic {{.*}} ins(%{{.*}} : memref<2x4xf32, #{{.*}}>) outs(%{{.*}} : memref<2x4xf32, 3>) attrs = {__internal_linalg_transform__ = "copy_to_workgroup_memory"}
//     CHECK-NOT:    gpu.barrier
//         CHECK:    linalg.generic {{.*}} ins(%{{.*}} : memref<4x256xf32, #{{.*}}>) outs(%{{.*}} : memref<4x256xf32, 3>) attrs = {__internal_linalg_transform__ = "copy_to_workgroup_memory"}
//         CHECK:    gpu.barrier
//         CHECK:    scf.for %[[IND0:.+]] = %{{.*}} to %[[C2]] step %[[C2]] {
//         CHECK:      scf.for %[[IND1:.+]] = %{{.*}} to %[[C256]] step %[[C256]] {
//     CHECK-DAG:        %[[A:.+]] = memref.subview %[[BUFFER1]][%[[IND0]], 0] [2, 4] [1, 1] : memref<2x4xf32, 3> to memref<2x4xf32, #{{.*}}, 3>
//     CHECK-DAG:        %[[B:.+]] = memref.subview %[[BUFFER0]][0, %[[IND1]]] [4, 4] [1, 1] : memref<4x256xf32, 3> to memref<4x4xf32, #{{.*}}, 3>
//     CHECK-DAG:        %[[C:.+]] = memref.subview %{{.*}}[%[[IND0]], %[[IND1]]] [2, 4] [1, 1] : memref<2x256xf32, #{{.*}}> to memref<2x4xf32, #{{.*}}>
//         CHECK:        linalg.matmul {__internal_linalg_transform__ = "vectorize", {{.*}}} ins(%[[A]], %[[B]] : memref<2x4xf32, #{{.*}}, 3>, memref<4x4xf32, #{{.*}}, 3>) outs(%[[C]] : memref<2x4xf32, #{{.*}}>)
//         CHECK:    }
//         CHECK:  }

// -----

#translation = #iree_codegen.translation.info<"LLVMGPUMatmulSimt", workload_per_wg = [32, 8, 1]>
#executable_target_cuda_nvptx_fb = #hal.executable.target<"cuda", "cuda-nvptx-fb">
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable private @batch_matmul_func  {
  hal.executable.variant @cuda, target = #executable_target_cuda_nvptx_fb {
    hal.executable.entry_point @batch_matmul_func layout(#executable_layout) {
      translation.info = #translation,
      workgroup_size = [8 : index, 8 : index, 1 : index]
    }
builtin.module {
  func @batch_matmul_func() {
    %c0 = arith.constant 0 : index
    %cst = arith.constant 0.000000e+00 : f32
    %c4 = arith.constant 4 : index
    %c32 = arith.constant 32 : index
    %c64 = arith.constant 64 : index
    %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) offset(%c0) alignment(32) : memref<4x32x1024xf32>
    memref.assume_alignment %0, 32 : memref<4x32x1024xf32>
    %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) offset(%c0) alignment(32) : memref<4x1024x64xf32>
    memref.assume_alignment %1, 32 : memref<4x1024x64xf32>
    %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) offset(%c0) alignment(32) : memref<4x32x64xf32>
    memref.assume_alignment %2, 32 : memref<4x32x64xf32>
    %workgroup_id_x = hal.interface.workgroup.id[0] : index
    %workgroup_count_x = hal.interface.workgroup.count[0] : index
    %workgroup_id_y = hal.interface.workgroup.id[1] : index
    %workgroup_count_y = hal.interface.workgroup.count[1] : index
    %workgroup_id_z = hal.interface.workgroup.id[2] : index
    %workgroup_count_z = hal.interface.workgroup.count[2] : index
    scf.for %arg0 = %workgroup_id_z to %c4 step %workgroup_count_z {
      %3 = affine.apply affine_map<()[s0] -> (s0 * 8)>()[%workgroup_id_y]
      %4 = affine.apply affine_map<()[s0] -> (s0 * 8)>()[%workgroup_count_y]
      scf.for %arg1 = %3 to %c32 step %4 {
        %5 = affine.apply affine_map<()[s0] -> (s0 * 32)>()[%workgroup_id_x]
        %6 = affine.apply affine_map<()[s0] -> (s0 * 32)>()[%workgroup_count_x]
        scf.for %arg2 = %5 to %c64 step %6 {
          %7 = memref.subview %0[%arg0, %arg1, 0] [1, 8, 1024] [1, 1, 1] : memref<4x32x1024xf32> to memref<1x8x1024xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 32768 + s0 + d1 * 1024 + d2)>>
          %8 = memref.subview %1[%arg0, 0, %arg2] [1, 1024, 32] [1, 1, 1] : memref<4x1024x64xf32> to memref<1x1024x32xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 65536 + s0 + d1 * 64 + d2)>>
          %9 = memref.subview %2[%arg0, %arg1, %arg2] [1, 8, 32] [1, 1, 1] : memref<4x32x64xf32> to memref<1x8x32xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 2048 + s0 + d1 * 64 + d2)>> 
          linalg.fill(%cst, %9) {lowering.config = #iree_codegen.lowering.config<tile_sizes = [[1, 8, 32, 32]], native_vector_size = []>} : f32, memref<1x8x32xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 2048 + s0 + d1 * 64 + d2)>>  
          linalg.batch_matmul {lowering.config = #iree_codegen.lowering.config<tile_sizes = [[1, 8, 32, 32]], native_vector_size = []>} ins(%7, %8 : memref<1x8x1024xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 32768 + s0 + d1 * 1024 + d2)>>, memref<1x1024x32xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 65536 + s0 + d1 * 64 + d2)>>) outs(%9 : memref<1x8x32xf32, affine_map<(d0, d1, d2)[s0] -> (d0 * 2048 + s0 + d1 * 64 + d2)>>)
        }
      }
    }
    return
  }
}
}
}

//         CHECK: #[[$MAP:.*]] = affine_map<()[s0] -> (s0 * 4)>
//   CHECK-LABEL: hal.executable private @batch_matmul_func
//         CHECK:   hal.executable.variant public @cuda
//     CHECK-DAG:   %[[C8:.+]] = arith.constant 8 : index
//     CHECK-DAG:   %[[C32:.+]] = arith.constant 32 : index
//     CHECK-DAG:   %[[TX:.*]] = gpu.thread_id  x
//     CHECK-DAG:   %[[TY:.*]] = gpu.thread_id  y
//         CHECK:   scf.for %{{.*}} = %[[TY]] to %[[C8]] step %[[C8]] {
//         CHECK:     %[[TX4:.*]] = affine.apply #[[$MAP]]()[%16]
//         CHECK:     scf.for %[[IND1:.+]] = %[[TX4]] to %[[C32]] step %[[C32]] {
//     CHECK-DAG:       memref.subview
//     CHECK-DAG:       memref.subview
//     CHECK-DAG:       memref.subview
//         CHECK:       linalg.batch_matmul {__internal_linalg_transform__ = "vectorize", {{.*}}} ins(%{{.*}}, %{{.*}} : memref<1x1x32xf32, #{{.*}}, 3>, memref<1x32x4xf32, #{{.*}}, 3>) outs(%{{.*}} : memref<1x1x4xf32, #{{.*}}>)
//         CHECK:    }
//         CHECK:  }

// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[2, 32, 4]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"LLVMGPUMatmulSimt", workload_per_wg = [32, 2]>
#executable_target_cuda_nvptx_fb = #hal.executable.target<"cuda", "cuda-nvptx-fb">
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
#map0 = affine_map<()[s0] -> (s0 * 2)>
#map1 = affine_map<()[s0] -> (s0 * 32)>
#map2 = affine_map<(d0) -> (2, -d0 + 1024)>
#map3 = affine_map<(d0) -> (32, -d0 + 1024)>
#map4 = affine_map<(d0, d1)[s0] -> (d0 * 1024 + s0 + d1)>
hal.executable private @dot_dispatch_0  {
  hal.executable.variant @cuda, target = #executable_target_cuda_nvptx_fb {
    hal.executable.entry_point @dot_dispatch_0 layout(#executable_layout) {
      translation.info = #translation,
      workgroup_size = [64 : index, 8 : index, 1 : index]
    }
    builtin.module {
      builtin.func @dot_dispatch_0() {
        %cst = arith.constant 0.000000e+00 : f32
        %c0 = arith.constant 0 : index
        %c1024 = arith.constant 1024 : index
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<1024x1024xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<1024x1024xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<1024x1024xf32>
        %workgroup_size_x = hal.interface.workgroup.size[0] : index
        %workgroup_size_y = hal.interface.workgroup.size[1] : index
        %workgroup_id_x = hal.interface.workgroup.id[0] : index
        %workgroup_count_x = hal.interface.workgroup.count[0] : index
        %workgroup_id_y = hal.interface.workgroup.id[1] : index
        %workgroup_count_y = hal.interface.workgroup.count[1] : index
        %3 = affine.apply #map0()[%workgroup_id_y]
        %4 = affine.apply #map0()[%workgroup_count_y]
        scf.for %arg0 = %3 to %c1024 step %4 {
          %5 = affine.apply #map1()[%workgroup_id_x]
          %6 = affine.apply #map1()[%workgroup_count_x]
          scf.for %arg1 = %5 to %c1024 step %6 {
            %8 = memref.subview %0[%arg0, 0] [2, 1024] [1, 1]
                : memref<1024x1024xf32> to memref<2x1024xf32, #map4>
            %10 = memref.subview %1[0, %arg1] [1024, 32] [1, 1]
                : memref<1024x1024xf32> to memref<1024x32xf32, #map4>
            %11 = memref.subview %2[%arg0, %arg1] [2, 32] [1, 1]
                : memref<1024x1024xf32> to memref<2x32xf32, #map4>
            linalg.fill(%cst, %11) {lowering.config = #config}
                : f32, memref<2x32xf32, #map4>
            linalg.matmul {lowering.config = #config}
                ins(%8, %10 : memref<2x1024xf32, #map4>, memref<1024x32xf32, #map4>)
                outs(%11 : memref<2x32xf32, #map4>)
          }
        }
        return
      }
    }
  }
}

//   CHECK-LABEL: hal.executable private @dot_dispatch_0
//         CHECK:   hal.executable.variant public @cuda
//     CHECK-DAG:  %[[C0:.+]] = arith.constant 0 : index
//     CHECK-DAG:  %[[C2:.+]] = arith.constant 2 : index
//     CHECK-DAG:  %[[C4:.+]] = arith.constant 4 : index
//     CHECK-DAG:  %[[C8:.+]] = arith.constant 8 : index
//     CHECK-DAG:  %[[C32:.+]] = arith.constant 32 : index
//     CHECK-DAG:  %[[C64:.+]] = arith.constant 64 : index
//     CHECK-DAG:  %[[C1024:.+]] = arith.constant 1024 : index
//     CHECK-DAG:  %[[BUFFER0:.+]] = memref.alloc() : memref<4x32xf32, 3>
//     CHECK-DAG:  %[[BUFFER1:.+]] = memref.alloc() : memref<2x4xf32, 3>
//         CHECK:  scf.for %[[K:.+]] = %[[C0]] to %[[C1024]] step %[[C4]] {
//         CHECK:    gpu.barrier
//         CHECK:    linalg.generic {{.*}} ins(%{{.*}} : memref<2x4xf32, #{{.*}}>) outs(%{{.*}} : memref<2x4xf32, 3>) attrs = {__internal_linalg_transform__ = "copy_to_workgroup_memory"}
//     CHECK-NOT:    gpu.barrier
//         CHECK:    linalg.generic {{.*}} ins(%{{.*}} : memref<4x32xf32, #{{.*}}>) outs(%{{.*}} : memref<4x32xf32, 3>) attrs = {__internal_linalg_transform__ = "copy_to_workgroup_memory"}
//         CHECK:    gpu.barrier
//         CHECK:    scf.for %[[IND0:.+]] = %{{.*}} to %[[C2]] step %[[C8]] {
//         CHECK:      scf.for %[[IND1:.+]] = %{{.*}} to %[[C32]] step %[[C64]] {
//     CHECK-DAG:        %[[A:.+]] = memref.subview %[[BUFFER1]][%[[IND0]], 0] [1, 4] [1, 1] : memref<2x4xf32, 3> to memref<1x4xf32, #{{.*}}, 3>
//     CHECK-DAG:        %[[B:.+]] = memref.subview %[[BUFFER0]][0, %[[IND1]]] [4, 1] [1, 1] : memref<4x32xf32, 3> to memref<4x1xf32, #{{.*}}, 3>
//     CHECK-DAG:        %[[C:.+]] = memref.subview %{{.*}}[%[[IND0]], %[[IND1]]] [1, 1] [1, 1] : memref<2x32xf32, #{{.*}}> to memref<1x1xf32, #{{.*}}>
//         CHECK:        linalg.matmul {__internal_linalg_transform__ = "vectorize", {{.*}}} ins(%[[A]], %[[B]] : memref<1x4xf32, #{{.*}}, 3>, memref<4x1xf32, #{{.*}}, 3>) outs(%[[C]] : memref<1x1xf32, #{{.*}}>)
//         CHECK:    }
//         CHECK:  }


// -----

#config = #iree_codegen.lowering.config<tile_sizes = [[]], native_vector_size = []>
#translation = #iree_codegen.translation.info<"LLVMGPUVectorize", workload_per_wg = []>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>
  ]>
]>
// Pure reducion case, skip tiling.
hal.executable @reduction_dispatch {
  hal.executable.variant @cuda, target = <"cuda", "cuda-nvptx-fb"> {
    hal.executable.entry_point @predict_dispatch_153 layout(#executable_layout) {
      translation.info = #translation,
      workgroup_size = [1: index, 1: index, 1: index]
    }
    builtin.module {
      builtin.func @predict_dispatch_153() {
        %c0 = arith.constant 0 : index
        %cst = arith.constant 0x7FC00000 : f32
        %cst_0 = arith.constant 0xFF800000 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<1000xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<f32>
        linalg.fill(%cst_0, %1) {lowering.config = #config}  : f32, memref<f32>
        linalg.generic {indexing_maps = [affine_map<(d0) -> (d0)>, affine_map<(d0) -> ()>], iterator_types = ["reduction"]} ins(%0 : memref<1000xf32>) outs(%1 : memref<f32>) attrs = {lowering.config = #config} {
        ^bb0(%arg0: f32, %arg1: f32):  // no predecessors
          %2 = arith.cmpf ogt, %arg0, %arg1 : f32
          %3 = arith.select %2, %arg0, %arg1 : f32
          %4 = arith.cmpf uno, %arg0, %arg1 : f32
          %5 = arith.select %4, %cst, %3 : f32
          linalg.yield %5 : f32
        }
        return
      }
    }
  }
}

//      CHECK: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[]{{\]}}, native_vector_size = []>
//      CHECK: hal.executable public @reduction_dispatch
//      CHECK: linalg.fill
// CHECK-SAME:     lowering.config = #[[CONFIG]]
//      CHECK: linalg.generic
// CHECK-SAME:     ins(%{{.*}} : memref<1000xf32>) outs(%{{.*}} : memref<f32>)
// CHECK-SAME:     lowering.config = #[[CONFIG]]
