// RUN: iree-opt -split-input-file -pass-pipeline='hal.executable(hal.executable.variant(iree-spirv-lower-executable-target-pass{test-lowering-configuration=true}))' %s | FileCheck %s

// Large matmul that can match the best tiling scheme.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @matmul_1024x2048x512 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @matmul_1024x2048x512 layout(#executable_layout)
    builtin.module {
      func @matmul_1024x2048x512() {
        %c0 = arith.constant 0 : index
        %c2048 = arith.constant 2048 : index
        %c1024 = arith.constant 1024 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:1024x512xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:512x2048xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:1024x2048xf32>
        %8 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [1024, 512], strides = [1, 1] : !flow.dispatch.tensor<readonly:1024x512xf32> -> tensor<1024x512xf32>
        %10 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [512, 2048], strides = [1, 1] : !flow.dispatch.tensor<readonly:512x2048xf32> -> tensor<512x2048xf32>
        %15 = linalg.init_tensor [1024, 2048] : tensor<1024x2048xf32>
        %16 = linalg.fill(%cst, %15) : f32, tensor<1024x2048xf32> -> tensor<1024x2048xf32>
        %17 = linalg.matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%8, %10 : tensor<1024x512xf32>, tensor<512x2048xf32>) outs(%16 : tensor<1024x2048xf32>) -> tensor<1024x2048xf32>
        flow.dispatch.tensor.store %17, %2, offsets = [0, 0], sizes = [1024, 2048], strides = [1, 1]
            : tensor<1024x2048xf32> -> !flow.dispatch.tensor<writeonly:1024x2048xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[8, 32], [4, 4], [0, 0, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @matmul_1024x2048x512
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [8 : index, 2 : index, 1 : index]
//      CHECK: func @matmul_1024x2048x512()
//      CHECK:   linalg.matmul
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Small matmul N that can still tile to all threads in a workgroup.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @matmul_3136x24x96 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @matmul_3136x24x96 layout(#executable_layout)
    builtin.module {
      func @matmul_3136x24x96() {
        %c0 = arith.constant 0 : index
        %c24 = arith.constant 24 : index
        %c3136 = arith.constant 3136 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:3136x96xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:96x24xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:3136x24xf32>
        %8 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [3136, 96], strides = [1, 1] : !flow.dispatch.tensor<readonly:3136x96xf32> -> tensor<3136x96xf32>
        %10 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [96, 24], strides = [1, 1] : !flow.dispatch.tensor<readonly:96x24xf32> -> tensor<96x24xf32>
        %15 = linalg.init_tensor [3136, 24] : tensor<3136x24xf32>
        %16 = linalg.fill(%cst, %15) : f32, tensor<3136x24xf32> -> tensor<3136x24xf32>
        %17 = linalg.matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%8, %10 : tensor<3136x96xf32>, tensor<96x24xf32>)
            outs(%16 : tensor<3136x24xf32>) -> tensor<3136x24xf32>
        flow.dispatch.tensor.store %17, %2, offsets = [0, 0], sizes = [3136, 24], strides = [1, 1]
            : tensor<3136x24xf32> -> !flow.dispatch.tensor<writeonly:3136x24xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[32, 8], [4, 4], [0, 0, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @matmul_3136x24x96
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [2 : index, 8 : index, 1 : index]
//      CHECK: func @matmul_3136x24x96()
//      CHECK:   linalg.matmul
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Small matmul M that can still tile to all threads in a workgroup.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @matmul_196x64x192 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @matmul_196x64x192 layout(#executable_layout)
    builtin.module {
      func @matmul_196x64x192() {
        %c0 = arith.constant 0 : index
        %c64 = arith.constant 64 : index
        %c196 = arith.constant 196 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:196x192xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:192x64xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:196x64xf32>
        %8 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [196, 192], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:196x192xf32> -> tensor<196x192xf32>
        %10 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [192, 64], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:192x64xf32> -> tensor<192x64xf32>
        %15 = linalg.init_tensor [196, 64] : tensor<196x64xf32>
        %16 = linalg.fill(%cst, %15) : f32, tensor<196x64xf32> -> tensor<196x64xf32>
        %17 = linalg.matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%8, %10 : tensor<196x192xf32>, tensor<192x64xf32>) outs(%16 : tensor<196x64xf32>) -> tensor<196x64xf32>
        flow.dispatch.tensor.store %17, %2, offsets = [0, 0], sizes = [196, 64], strides = [1, 1]
            : tensor<196x64xf32> -> !flow.dispatch.tensor<writeonly:196x64xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[4, 32], [2, 4], [0, 0, 8]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @matmul_196x64x192
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [8 : index, 2 : index, 1 : index]
//      CHECK: func @matmul_196x64x192()
//      CHECK:   linalg.matmul
// CHECK-SAME:      lowering.config = #[[CONFIG]]

// -----

// Small matmul K that can still tile to all threads in a workgroup.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @matmul_12544x96x16 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @matmul_12544x96x16 layout(#executable_layout)
    builtin.module {
      func @matmul_12544x96x16() {
        %c0 = arith.constant 0 : index
        %c96 = arith.constant 96 : index
        %c12544 = arith.constant 12544 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : memref<12544x16xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : memref<16x96xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : memref<12544x96xf32>
        linalg.fill(%cst, %2) : f32, memref<12544x96xf32>
        linalg.matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%0, %1 : memref<12544x16xf32>, memref<16x96xf32>) outs(%2 : memref<12544x96xf32>)
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[8, 32], [4, 4], [0, 0, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @matmul_12544x96x16
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [8 : index, 2 : index, 1 : index]
//      CHECK: func @matmul_12544x96x16()
//      CHECK:   linalg.matmul
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Odd matmul M and small N that cannot utilize all threads in a workgroup.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @matmul_49x160x576 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @matmul_49x160x576 layout(#executable_layout)
    builtin.module {
      func @matmul_49x160x576() {
        %c0 = arith.constant 0 : index
        %c160 = arith.constant 160 : index
        %c49 = arith.constant 49 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:49x576xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:576x160xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:49x160xf32>
        %8 = flow.dispatch.tensor.load %0, offsets = [0, 0], sizes = [49, 576], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:49x576xf32> -> tensor<49x576xf32>
        %10 = flow.dispatch.tensor.load %1, offsets = [0, 0], sizes = [576, 160], strides = [1, 1]
            : !flow.dispatch.tensor<readonly:576x160xf32> -> tensor<576x160xf32>
        %15 = linalg.init_tensor [49, 160] : tensor<49x160xf32>
        %16 = linalg.fill(%cst, %15) : f32, tensor<49x160xf32> -> tensor<49x160xf32>
        %17 = linalg.matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%8, %10 : tensor<49x576xf32>, tensor<576x160xf32>) outs(%16 : tensor<49x160xf32>) -> tensor<49x160xf32>
        flow.dispatch.tensor.store %17, %2, offsets = [0, 0], sizes = [49, 160], strides = [1, 1]
            : tensor<49x160xf32> -> !flow.dispatch.tensor<writeonly:49x160xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[1, 32], [1, 4], [0, 0, 8]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @matmul_49x160x576
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [8 : index, 1 : index, 1 : index]
//      CHECK: func @matmul_49x160x576()
//      CHECK:   linalg.matmul
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Large batch matmul.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @batch_matmul_4x384x384 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @batch_matmul_4x384x384 layout(#executable_layout)
    builtin.module {
      func @batch_matmul_4x384x384() {
        %c0 = arith.constant 0 : index
        %c384 = arith.constant 384 : index
        %c4 = arith.constant 4 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:4x384x32xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:4x32x384xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:4x384x384xf32>
        %11 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0], sizes = [4, 384, 32], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:4x384x32xf32> -> tensor<4x384x32xf32>
        %14 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0], sizes = [4, 32, 384], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:4x32x384xf32> -> tensor<4x32x384xf32>
        %21 = linalg.init_tensor [4, 384, 384] : tensor<4x384x384xf32>
        %22 = linalg.fill(%cst, %21) : f32, tensor<4x384x384xf32> -> tensor<4x384x384xf32>
        %23 = linalg.batch_matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%11, %14 : tensor<4x384x32xf32>, tensor<4x32x384xf32>)
            outs(%22 : tensor<4x384x384xf32>) -> tensor<4x384x384xf32>
        flow.dispatch.tensor.store %23, %2, offsets = [0, 0, 0], sizes = [4, 384, 384], strides = [1, 1, 1]
            : tensor<4x384x384xf32> -> !flow.dispatch.tensor<writeonly:4x384x384xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[1, 12, 32], [1, 6, 4], [0, 0, 0, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @batch_matmul_4x384x384
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [8 : index, 2 : index, 1 : index]
//      CHECK: func @batch_matmul_4x384x384()
//      CHECK:   linalg.batch_matmul
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Small batch matmul.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @batch_matmul_4x2x8 {
  hal.executable.variant @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, ARM:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 512 : i32,
        max_compute_workgroup_size = dense<512> : vector<3xi32>,
       subgroup_size = 16 : i32}>
    }> {
    hal.executable.entry_point @batch_matmul_4x2x8 layout(#executable_layout)
    builtin.module {
      func @batch_matmul_4x2x8() {
        %c0 = arith.constant 0 : index
        %c8 = arith.constant 8 : index
        %c2 = arith.constant 2 : index
        %c4 = arith.constant 4 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:4x2x32xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:4x32x8xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:4x2x8xf32>
        %11 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0], sizes = [4, 2, 32], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:4x2x32xf32> -> tensor<4x2x32xf32>
        %14 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0], sizes = [4, 32, 8], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:4x32x8xf32> -> tensor<4x32x8xf32>
        %21 = linalg.init_tensor [4, 2, 8] : tensor<4x2x8xf32>
        %22 = linalg.fill(%cst, %21) : f32, tensor<4x2x8xf32> -> tensor<4x2x8xf32>
        %23 = linalg.batch_matmul {__internal_linalg_transform__ = "workgroup"}
            ins(%11, %14 : tensor<4x2x32xf32>, tensor<4x32x8xf32>) outs(%22 : tensor<4x2x8xf32>) -> tensor<4x2x8xf32>
        flow.dispatch.tensor.store %23, %2, offsets = [0, 0, 0], sizes = [4, 2, 8], strides = [1, 1, 1]
            : tensor<4x2x8xf32> -> !flow.dispatch.tensor<writeonly:4x2x8xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[1, 2, 8], [1, 1, 4], [0, 0, 0, 8]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @batch_matmul_4x2x8
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [2 : index, 2 : index, 1 : index]
//      CHECK: func @batch_matmul_4x2x8()
//      CHECK:   linalg.batch_matmul
// CHECK-SAME:     lowering.config = #[[CONFIG]]
