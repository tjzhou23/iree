// RUN: iree-opt -split-input-file -iree-hal-conversion -canonicalize -cse %s | FileCheck %s

// Tests an end-to-end simple single-dispatch `dispatch(arg0, arg1) -> result`.

#executable_target_embedded_elf_x86_64_ = #hal.executable.target<"llvm", "embedded-elf-x86_64">
#device_target_cpu = #hal.device.target<"cpu", {
  executable_targets = [#executable_target_embedded_elf_x86_64_]
}>
#executable_layout = #hal.executable.layout<push_constants = 0, sets = [
  #hal.descriptor_set.layout<0, bindings = [
    #hal.descriptor_set.binding<0, storage_buffer>,
    #hal.descriptor_set.binding<1, storage_buffer>,
    #hal.descriptor_set.binding<2, storage_buffer>
  ]>
]>

// CHECK: module
module attributes {hal.device.targets = [#device_target_cpu]}  {

  // CHECK: hal.executable private @ex
  hal.executable private @ex {
    hal.executable.variant public @embedded_elf_x86_64, target = #executable_target_embedded_elf_x86_64_ {
      hal.executable.entry_point public @dispatch ordinal(0) layout(#executable_layout) {
        translation.info = #iree_codegen.translation.info<"CPUDefault", workload_per_wg = [4]>
      } {
      ^bb0(%arg0: index, %arg1: index, %arg2: index):  // no predecessors
        %c1 = arith.constant 1 : index
        %0 = affine.apply affine_map<()[s0] -> (s0 ceildiv 4)>()[%arg0]
        hal.return %0, %c1, %c1 : index, index, index
      }
      builtin.module {
        // Opaque at this point (in some target-specific dialects).
      }
    }
  }

  // CHECK-LABEL: func @simpleDispatch
  //  CHECK-SAME: (%[[ARG0:.+]]: !hal.buffer_view, %[[ARG1:.+]]: !hal.buffer_view) -> !hal.buffer_view
  func @simpleDispatch(%arg0: !hal.buffer_view, %arg1: !hal.buffer_view) -> !hal.buffer_view attributes {iree.abi.stub} {
    %c1 = arith.constant 1 : index
    %c4 = arith.constant 4 : index
    %c16 = arith.constant 16 : index
    %c0 = arith.constant 0 : index

    // CHECK: %[[ARG0_BUFFER:.+]] = hal.buffer_view.buffer<%[[ARG0]] : !hal.buffer_view> : !hal.buffer

    // (annoyingly out of order)
    // CHECK-DAG: %[[DEVICE:.+]] = hal.ex.shared_device : !hal.device
    // CHECK-DAG: %[[ALLOCATOR:.+]] = hal.device.allocator<%[[DEVICE]] : !hal.device> : !hal.allocator

    // CHECK: hal.buffer.assert<%[[ARG0_BUFFER]] : !hal.buffer>
    // CHECK-SAME: message("tensor")
    // CHECK-SAME: allocator(%[[ALLOCATOR]] : !hal.allocator)
    // CHECK-SAME: minimum_length(%c16)
    // CHECK-SAME: type(DeviceVisible)
    // CHECK-SAME: usage("Transfer|Dispatch")
    %arg0_resource = stream.tensor.import %arg0 : !hal.buffer_view -> tensor<4xf32> in !stream.resource<external>{%c16}

    // CHECK: %[[ARG1_BUFFER:.+]] = hal.buffer_view.buffer<%[[ARG1]] : !hal.buffer_view> : !hal.buffer
    // CHECK: hal.buffer.assert<%[[ARG1_BUFFER]] : !hal.buffer>
    // CHECK-SAME: message("tensor")
    // CHECK-SAME: allocator(%[[ALLOCATOR]] : !hal.allocator)
    // CHECK-SAME: minimum_length(%c16)
    // CHECK-SAME: type(DeviceVisible)
    // CHECK-SAME: usage("Transfer|Dispatch")
    %arg1_resource = stream.tensor.import %arg1 : !hal.buffer_view -> tensor<4xf32> in !stream.resource<external>{%c16}

    // CHECK: %[[RESULT_BUFFER:.+]] = hal.allocator.allocate<%[[ALLOCATOR]] : !hal.allocator>
    // CHECK-SAME: type("HostVisible|DeviceVisible|DeviceLocal")
    // CHECK-SAME: usage("Transfer|Mapping|Dispatch|All")
    // CHECK-SAME: : !hal.buffer{%c16}
    %result_resource = stream.resource.alloc uninitialized : !stream.resource<external>{%c16}

    // CHECK: %[[CMD:.+]] = hal.command_buffer.create
    // CHECK-SAME: device(%[[DEVICE]] : !hal.device)
    // CHECK-SAME: mode("OneShot|AllowInlineExecution")
    // CHECK-SAME: categories("Transfer|Dispatch") : !hal.command_buffer
    // CHECK: hal.command_buffer.begin<%[[CMD]] : !hal.command_buffer>
    %timepoint = stream.cmd.execute
        with(%arg0_resource as %arg0_capture: !stream.resource<external>{%c16},
             %arg1_resource as %arg1_capture: !stream.resource<external>{%c16},
             %result_resource as %result_capture: !stream.resource<external>{%c16}) {

      // CHECK: hal.device.switch<%[[DEVICE]] : !hal.device>
      // CHECK: #hal.device.match.executable.format<"embedded-elf-x86_64"> {
      // CHECK:   %[[EXECUTABLE_LAYOUT:.+]] = hal.executable_layout.lookup
      // CHECK-SAME: device(%[[DEVICE]] : !hal.device)
      // CHECK-SAME: layout(#executable_layout) : !hal.executable_layout
      // CHECK:   hal.command_buffer.push_descriptor_set<%[[CMD]] : !hal.command_buffer>
      // CHECK-SAME: layout(%[[EXECUTABLE_LAYOUT]] : !hal.executable_layout)[%c0]
      // CHECK-SAME: bindings([
      // CHECK:     %c0 = (%[[ARG0_BUFFER]] : !hal.buffer)[%c0, %c16],
      // CHECK:     %c1 = (%[[ARG1_BUFFER]] : !hal.buffer)[%c0, %c16],
      // CHECK:     %c2 = (%[[RESULT_BUFFER]] : !hal.buffer)[%c0, %c16]
      // CHECK:   ])
      // CHECK:   hal.command_buffer.dispatch.symbol<%[[CMD]] : !hal.command_buffer>
      // CHECK-SAME: target(@ex::@embedded_elf_x86_64::@dispatch)
      // CHECK-SAME: workgroups([%c1, %c1, %c1])
      // CHECK:   hal.return
      // CHECK: }
      stream.cmd.dispatch @ex::@dispatch[%c4, %c1, %c1] {
        ro %arg0_capture[%c0 for %c16] : !stream.resource<external>{%c16},
        ro %arg1_capture[%c0 for %c16] : !stream.resource<external>{%c16},
        wo %result_capture[%c0 for %c16] : !stream.resource<external>{%c16}
      } attributes {
        hal.interface.bindings = [
          #hal.interface.binding<0, 0>,
          #hal.interface.binding<0, 1>,
          #hal.interface.binding<0, 2>
        ]
      }

    // CHECK: hal.command_buffer.execution_barrier<%[[CMD]] : !hal.command_buffer>
    // CHECK-SAME: source("Dispatch|Transfer|CommandRetire")
    // CHECK-SAME: target("CommandIssue|Dispatch|Transfer")
    // CHECK: hal.command_buffer.end<%[[CMD]] : !hal.command_buffer>
    } => !stream.timepoint

    // CHECK: hal.ex.submit_and_wait %[[DEVICE]], %[[CMD]]
    %result_ready = stream.timepoint.await %timepoint => %result_resource : !stream.resource<external>{%c16}

    // CHECK: %[[RESULT_VIEW:.+]] = hal.buffer_view.create
    // CHECK-SAME: buffer(%[[RESULT_BUFFER]] : !hal.buffer)
    // CHECK-SAME: shape([%c4])
    // CHECK-SAME: type(%c553648160_i32)
    // CHECK-SAME: encoding(%c1_i32)
    %result_view = stream.tensor.export %result_ready : tensor<4xf32> in !stream.resource<external>{%c16} -> !hal.buffer_view
    // CHECK: return
    return %result_view : !hal.buffer_view
  }

}
