// RUN: iree-opt -split-input-file -pass-pipeline='hal.executable(hal.executable.variant(iree-spirv-lower-executable-target-pass{test-lowering-configuration=true}))' %s | FileCheck %s

// Conv - large OC - distribute to only one workgroup dimension.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @conv_112x112x512 {
  hal.executable.variant public @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, Qualcomm:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 1024 : i32,
        max_compute_workgroup_size = dense<[1024, 1024, 64]> : vector<3xi32>,
        subgroup_size = 64 : i32}>
    }> {
    hal.executable.entry_point public @conv_112x112x512 layout(#executable_layout)
    builtin.module {
      func @conv_112x112x512() {
        %c0 = arith.constant 0 : index
        %c512 = arith.constant 512 : index
        %c112 = arith.constant 112 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:1x225x225x3xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:3x3x3x512xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:1x112x112x512xf32>
        %13 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 225, 225, 3], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x225x225x3xf32> -> tensor<1x225x225x3xf32>
        %15 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0, 0], sizes = [3, 3, 3, 512], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:3x3x3x512xf32> -> tensor<3x3x3x512xf32>
        %22 = linalg.init_tensor [1, 112, 112, 512] : tensor<1x112x112x512xf32>
        %23 = linalg.fill(%cst, %22) : f32, tensor<1x112x112x512xf32> -> tensor<1x112x112x512xf32>
        %24 = linalg.conv_2d_nhwc_hwcf {__internal_linalg_transform__ = "workgroup", dilations = dense<1> : tensor<2xi64>, strides = dense<2> : tensor<2xi64>}
            ins(%13, %15 : tensor<1x225x225x3xf32>, tensor<3x3x3x512xf32>) outs(%23 : tensor<1x112x112x512xf32>) -> tensor<1x112x112x512xf32>
        flow.dispatch.tensor.store %24, %2, offsets = [0, 0, 0, 0], sizes = [1, 112, 112, 512], strides = [1, 1, 1, 1]
            : tensor<1x112x112x512xf32> -> !flow.dispatch.tensor<writeonly:1x112x112x512xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[0, 1, 8, 256], [0, 1, 8, 4], [0, 0, 0, 0, 1, 1, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @conv_112x112x512
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [64 : index, 1 : index, 1 : index]
//      CHECK: func @conv_112x112x512()
//      CHECK:   linalg.conv_2d_nhwc_hwcf
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Conv - medium OC/OW/OH - distribute to two workgroup dimensions.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @conv_112x112x32 {
  hal.executable.variant public @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, Qualcomm:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 1024 : i32,
        max_compute_workgroup_size = dense<[1024, 1024, 64]> : vector<3xi32>,
        subgroup_size = 64 : i32}>
    }> {
    hal.executable.entry_point public @conv_112x112x32 layout(#executable_layout)
    builtin.module {
      func @conv_112x112x32() {
        %c0 = arith.constant 0 : index
        %c32 = arith.constant 32 : index
        %c112 = arith.constant 112 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:1x225x225x3xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:3x3x3x32xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:1x112x112x32xf32>
        %13 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 225, 225, 3], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x225x225x3xf32> -> tensor<1x225x225x3xf32>
        %15 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0, 0], sizes = [3, 3, 3, 32], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:3x3x3x32xf32> -> tensor<3x3x3x32xf32>
        %22 = linalg.init_tensor [1, 112, 112, 32] : tensor<1x112x112x32xf32>
        %23 = linalg.fill(%cst, %22) : f32, tensor<1x112x112x32xf32> -> tensor<1x112x112x32xf32>
        %24 = linalg.conv_2d_nhwc_hwcf {__internal_linalg_transform__ = "workgroup", dilations = dense<1> : tensor<2xi64>, strides = dense<2> : tensor<2xi64>}
            ins(%13, %15 : tensor<1x225x225x3xf32>, tensor<3x3x3x32xf32>) outs(%23 : tensor<1x112x112x32xf32>) -> tensor<1x112x112x32xf32>
        flow.dispatch.tensor.store %24, %2, offsets = [0, 0, 0, 0], sizes = [1, 112, 112, 32], strides = [1, 1, 1, 1]
            : tensor<1x112x112x32xf32> -> !flow.dispatch.tensor<writeonly:1x112x112x32xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[0, 4, 16, 32], [0, 4, 2, 4], [0, 0, 0, 0, 1, 1, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @conv_112x112x32
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [8 : index, 8 : index, 1 : index]
//      CHECK: func @conv_112x112x32()
//      CHECK:   linalg.conv_2d_nhwc_hwcf
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Conv - small OC/OW/OH - distribute to all three workgroup dimensions.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @conv_16x16x16 {
  hal.executable.variant public @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, Qualcomm:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 1024 : i32,
        max_compute_workgroup_size = dense<[1024, 1024, 64]> : vector<3xi32>,
        subgroup_size = 64 : i32}>
    }> {
    hal.executable.entry_point public @conv_16x16x16 layout(#executable_layout)
    builtin.module {
      func @conv_16x16x16() {
        %c0 = arith.constant 0 : index
        %c16 = arith.constant 16 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:1x33x33x3xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:3x3x3x16xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:1x16x16x16xf32>
        %13 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 33, 33, 3], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x33x33x3xf32> -> tensor<1x33x33x3xf32>
        %15 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0, 0], sizes = [3, 3, 3, 16], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:3x3x3x16xf32> -> tensor<3x3x3x16xf32>
        %22 = linalg.init_tensor [1, 16, 16, 16] : tensor<1x16x16x16xf32>
        %23 = linalg.fill(%cst, %22) : f32, tensor<1x16x16x16xf32> -> tensor<1x16x16x16xf32>
        %24 = linalg.conv_2d_nhwc_hwcf {__internal_linalg_transform__ = "workgroup", dilations = dense<1> : tensor<2xi64>, strides = dense<2> : tensor<2xi64>}
            ins(%13, %15 : tensor<1x33x33x3xf32>, tensor<3x3x3x16xf32>) outs(%23 : tensor<1x16x16x16xf32>) -> tensor<1x16x16x16xf32>
        flow.dispatch.tensor.store %24, %2, offsets = [0, 0, 0, 0], sizes = [1, 16, 16, 16], strides = [1, 1, 1, 1]
            : tensor<1x16x16x16xf32> -> !flow.dispatch.tensor<writeonly:1x16x16x16xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[0, 8, 8, 16], [0, 2, 2, 4], [0, 0, 0, 0, 1, 1, 4]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @conv_16x16x16
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [4 : index, 4 : index, 4 : index]

//      CHECK: func @conv_16x16x16()
//      CHECK:   linalg.conv_2d_nhwc_hwcf
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Depthwise conv - small OC/OW/OH - distribute to all three workgroup dimensions.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @dwconv_28x28x144 {
  hal.executable.variant public @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, Qualcomm:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 1024 : i32,
        max_compute_workgroup_size = dense<[1024, 1024, 64]> : vector<3xi32>,
        subgroup_size = 64 : i32}>
    }> {
    hal.executable.entry_point public @dwconv_28x28x144 layout(#executable_layout)
    builtin.module {
      func @dwconv_28x28x144() {
        %c0 = arith.constant 0 : index
        %c144 = arith.constant 144 : index
        %c28 = arith.constant 28 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:1x57x57x144xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:3x3x144xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:1x28x28x144xf32>
        %14 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 57, 57, 144], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x57x57x144xf32> -> tensor<1x57x57x144xf32>
        %16 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0], sizes = [3, 3, 144], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:3x3x144xf32> -> tensor<3x3x144xf32>
        %23 = linalg.init_tensor [1, 28, 28, 144] : tensor<1x28x28x144xf32>
        %24 = linalg.fill(%cst, %23) : f32, tensor<1x28x28x144xf32> -> tensor<1x28x28x144xf32>
        %25 = linalg.depthwise_conv_2d_nhwc_hwc {__internal_linalg_transform__ = "workgroup", dilations = dense<1> : tensor<2xi64>, strides = dense<2> : tensor<2xi64>}
                  ins(%14, %16 : tensor<1x57x57x144xf32>, tensor<3x3x144xf32>) outs(%24 : tensor<1x28x28x144xf32>) -> tensor<1x28x28x144xf32>
        flow.dispatch.tensor.store %25, %2, offsets = [0, 0, 0, 0], sizes = [1, 28, 28, 144], strides = [1, 1, 1, 1]
            : tensor<1x28x28x144xf32> -> !flow.dispatch.tensor<writeonly:1x28x28x144xf32>
        return
      }
    }
  }
}

//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[0, 4, 4, 16], [0, 1, 1, 4], [0, 0, 0, 0, 1, 1]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @dwconv_28x28x144
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [4 : index, 4 : index, 4 : index]
//      CHECK: func @dwconv_28x28x144()
//      CHECK:   linalg.depthwise_conv_2d_nhwc_hwc
// CHECK-SAME:     lowering.config = #[[CONFIG]]

// -----

// Depthwise conv - tiny OC/OW/OH - starving the GPU.

#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>
hal.executable @dwconv_4x4x8 {
  hal.executable.variant public @vulkan_spirv_fb, target = <"vulkan", "vulkan-spirv-fb", {
      spv.target_env = #spv.target_env<#spv.vce<v1.4, [Shader], []>, Qualcomm:IntegratedGPU, {
        max_compute_shared_memory_size = 32768 : i32,
        max_compute_workgroup_invocations = 1024 : i32,
        max_compute_workgroup_size = dense<[1024, 1024, 64]> : vector<3xi32>,
        subgroup_size = 64 : i32}>
    }> {
    hal.executable.entry_point public @dwconv_4x4x8 layout(#executable_layout)
    builtin.module {
      func @dwconv_4x4x8() {
        %c0 = arith.constant 0 : index
        %c8 = arith.constant 8 : index
        %c4 = arith.constant 4 : index
        %cst = arith.constant 0.000000e+00 : f32
        %0 = hal.interface.binding.subspan set(0) binding(0) type(storage_buffer) : !flow.dispatch.tensor<readonly:1x9x9x8xf32>
        %1 = hal.interface.binding.subspan set(0) binding(1) type(storage_buffer) : !flow.dispatch.tensor<readonly:3x3x8xf32>
        %2 = hal.interface.binding.subspan set(0) binding(2) type(storage_buffer) : !flow.dispatch.tensor<writeonly:1x4x4x8xf32>
        %14 = flow.dispatch.tensor.load %0, offsets = [0, 0, 0, 0], sizes = [1, 9, 9, 8], strides = [1, 1, 1, 1]
            : !flow.dispatch.tensor<readonly:1x9x9x8xf32> -> tensor<1x9x9x8xf32>
        %16 = flow.dispatch.tensor.load %1, offsets = [0, 0, 0], sizes = [3, 3, 8], strides = [1, 1, 1]
            : !flow.dispatch.tensor<readonly:3x3x8xf32> -> tensor<3x3x8xf32>
        %23 = linalg.init_tensor [1, 4, 4, 8] : tensor<1x4x4x8xf32>
        %24 = linalg.fill(%cst, %23) : f32, tensor<1x4x4x8xf32> -> tensor<1x4x4x8xf32>
        %25 = linalg.depthwise_conv_2d_nhwc_hwc {__internal_linalg_transform__ = "workgroup", dilations = dense<1> : tensor<2xi64>, strides = dense<2> : tensor<2xi64>}
            ins(%14, %16 : tensor<1x9x9x8xf32>, tensor<3x3x8xf32>) outs(%24 : tensor<1x4x4x8xf32>) -> tensor<1x4x4x8xf32>
        flow.dispatch.tensor.store %25, %2, offsets = [0, 0, 0, 0], sizes = [1, 4, 4, 8], strides = [1, 1, 1, 1]
            : tensor<1x4x4x8xf32> -> !flow.dispatch.tensor<writeonly:1x4x4x8xf32>
        return
      }
    }
  }
}
//  CHECK-DAG: #[[CONFIG:.+]] = #iree_codegen.lowering.config<tile_sizes = {{\[}}[0, 4, 4, 8], [0, 1, 1, 4], [0, 0, 0, 0, 1, 1]{{\]}}, native_vector_size = []>
//  CHECK-DAG: #[[TRANSLATION:.+]] = #iree_codegen.translation.info<"SPIRVVectorize", workload_per_wg = []>
//      CHECK: hal.executable.entry_point public @dwconv_4x4x8
// CHECK-SAME:   translation.info = #[[TRANSLATION]]
// CHECK-SAME:   workgroup_size = [2 : index, 4 : index, 4 : index]
//      CHECK: func @dwconv_4x4x8()
//      CHECK:   linalg.depthwise_conv_2d_nhwc_hwc
// CHECK-SAME:     lowering.config = #[[CONFIG]]
