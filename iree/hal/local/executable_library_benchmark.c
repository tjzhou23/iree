// Copyright 2021 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iree/base/api.h"
#include "iree/base/internal/flags.h"
#include "iree/base/tracing.h"
#include "iree/hal/api.h"
#include "iree/hal/local/executable_library.h"
#include "iree/hal/local/executable_loader.h"
#include "iree/hal/local/local_descriptor_set_layout.h"
#include "iree/hal/local/local_executable.h"
#include "iree/hal/local/local_executable_layout.h"
#include "iree/testing/benchmark.h"

IREE_FLAG(string, executable_format, "",
          "Format of the executable file being loaded.");
IREE_FLAG(string, executable_file, "",
          "Path to the executable library file to load.");

IREE_FLAG(int32_t, entry_point, 0, "Entry point ordinal to run.");

IREE_FLAG(int32_t, workgroup_count_x, 1,
          "X dimension of the workgroup count defining the number of\n"
          "workgroup invocations that will be run per benchmark iteration.\n"
          "This is the fastest-changing dimension.");
IREE_FLAG(int32_t, workgroup_count_y, 1,
          "Y dimension of the workgroup count defining the number of\n"
          "workgroup invocations that will be run per benchmark iteration.");
IREE_FLAG(int32_t, workgroup_count_z, 1,
          "Z dimension of the workgroup count defining the number of\n"
          "workgroup invocations that will be run per benchmark iteration.\n"
          "This is the slowest-changing dimension.");
IREE_FLAG(int32_t, workgroup_size_x, 1,
          "X dimension of the workgroup size passed to the executable.");
IREE_FLAG(int32_t, workgroup_size_y, 1,
          "Y dimension of the workgroup size passed to the executable.");
IREE_FLAG(int32_t, workgroup_size_z, 1,
          "Z dimension of the workgroup size passed to the executable.");

// Total number of bindings we (currently) allow any executable to have.
#define IREE_HAL_LOCAL_MAX_TOTAL_BINDING_COUNT \
  (IREE_HAL_LOCAL_MAX_DESCRIPTOR_SET_COUNT *   \
   IREE_HAL_LOCAL_MAX_DESCRIPTOR_BINDING_COUNT)

// Parsed parameters from flags.
// Used to construct the dispatch parameters for the benchmark invocation.
struct {
  int32_t push_constant_count;
  union {
    uint32_t ui32;
  } push_constants[IREE_HAL_LOCAL_MAX_PUSH_CONSTANT_COUNT];

  int32_t binding_count;
  iree_string_view_t bindings[IREE_HAL_LOCAL_MAX_TOTAL_BINDING_COUNT];
} dispatch_params = {
    .push_constant_count = 0,
    .binding_count = 0,
};

static iree_status_t parse_push_constant(iree_string_view_t flag_name,
                                         void* storage,
                                         iree_string_view_t value) {
  IREE_ASSERT_LE(dispatch_params.push_constant_count + 1,
                 IREE_ARRAYSIZE(dispatch_params.push_constants),
                 "too many push constants");
  dispatch_params.push_constants[dispatch_params.push_constant_count++].ui32 =
      atoi(value.data);
  return iree_ok_status();
}
static void print_push_constant(iree_string_view_t flag_name, void* storage,
                                FILE* file) {
  if (dispatch_params.push_constant_count == 0) {
    fprintf(file, "# --%.*s=[integer value]\n", (int)flag_name.size,
            flag_name.data);
    return;
  }
  for (int32_t i = 0; i < dispatch_params.push_constant_count; ++i) {
    fprintf(file, "--%.*s=%u", (int)flag_name.size, flag_name.data,
            dispatch_params.push_constants[i].ui32);
    if (i < dispatch_params.push_constant_count - 1) {
      fprintf(file, "\n");
    }
  }
}
IREE_FLAG_CALLBACK(parse_push_constant, print_push_constant, &dispatch_params,
                   push_constant_callback,
                   "Appends a uint32_t push constant value.\n");

static iree_status_t parse_binding(iree_string_view_t flag_name, void* storage,
                                   iree_string_view_t value) {
  IREE_ASSERT_LE(dispatch_params.binding_count + 1,
                 IREE_ARRAYSIZE(dispatch_params.bindings), "too many bindings");
  dispatch_params.bindings[dispatch_params.binding_count++] = value;
  return iree_ok_status();
}
static void print_binding(iree_string_view_t flag_name, void* storage,
                          FILE* file) {
  if (dispatch_params.binding_count == 0) {
    fprintf(file, "# --%.*s=\"shapextype[=values]\"\n", (int)flag_name.size,
            flag_name.data);
    return;
  }
  for (int32_t i = 0; i < dispatch_params.binding_count; ++i) {
    const iree_string_view_t binding_str = dispatch_params.bindings[i];
    fprintf(file, "--%.*s=\"%.*s\"\n", (int)flag_name.size, flag_name.data,
            (int)binding_str.size, binding_str.data);
  }
}
IREE_FLAG_CALLBACK(
    parse_binding, print_binding, &dispatch_params, binding,
    "Appends a binding to the dispatch parameters.\n"
    "Bindings are defined by their shape, element type, and their data.\n"
    "Examples:\n"
    "  # 16 4-byte elements zero-initialized:\n"
    "  --binding=2x8xi32\n"
    "  # 10000 bytes all initialized to 123:\n"
    "  --binding=10000xi8=123\n"
    "  # 2 4-byte floating-point values with contents [[1.4], [2.1]]:\n"
    "  --binding=2x1xf32=1.4,2.1");

#if defined(IREE_HAL_HAVE_EMBEDDED_LIBRARY_LOADER)
#include "iree/hal/local/loaders/embedded_library_loader.h"
#endif  // IREE_HAL_HAVE_EMBEDDED_LIBRARY_LOADER

// Creates an executable loader based on the given format flag.
static iree_status_t iree_hal_executable_library_create_loader(
    iree_allocator_t host_allocator,
    iree_hal_executable_loader_t** out_executable_loader) {
#if defined(IREE_HAL_HAVE_EMBEDDED_LIBRARY_LOADER)
  if (strcmp(FLAG_executable_format, "EX_ELF") == 0) {
    return iree_hal_embedded_library_loader_create(
        iree_hal_executable_import_provider_null(), host_allocator,
        out_executable_loader);
  }
#endif  // IREE_HAL_HAVE_EMBEDDED_LIBRARY_LOADER
  return iree_make_status(
      IREE_STATUS_UNAVAILABLE,
      "no loader available that can handle --executable_format=%s",
      FLAG_executable_format);
}

// TODO(benvanik): use this to replace file_io.cc.
static iree_status_t iree_file_read_contents(const char* path,
                                             iree_allocator_t allocator,
                                             iree_byte_span_t* out_contents) {
  IREE_TRACE_ZONE_BEGIN(z0);
  *out_contents = iree_make_byte_span(NULL, 0);
  FILE* file = fopen(path, "rb");
  if (file == NULL) {
    IREE_TRACE_ZONE_END(z0);
    return iree_make_status(iree_status_code_from_errno(errno),
                            "failed to open file '%s'", path);
  }
  iree_status_t status = iree_ok_status();
  if (fseek(file, 0, SEEK_END) == -1) {
    status = iree_make_status(iree_status_code_from_errno(errno), "seek (end)");
  }
  size_t file_size = 0;
  if (iree_status_is_ok(status)) {
    file_size = ftell(file);
    if (file_size == -1L) {
      status =
          iree_make_status(iree_status_code_from_errno(errno), "size query");
    }
  }
  if (iree_status_is_ok(status)) {
    if (fseek(file, 0, SEEK_SET) == -1) {
      status =
          iree_make_status(iree_status_code_from_errno(errno), "seek (beg)");
    }
  }
  // Allocate +1 to force a trailing \0 in case this is a string.
  char* contents = NULL;
  if (iree_status_is_ok(status)) {
    status = iree_allocator_malloc(allocator, file_size + 1, (void**)&contents);
  }
  if (iree_status_is_ok(status)) {
    if (fread(contents, file_size, 1, file) != 1) {
      status =
          iree_make_status(iree_status_code_from_errno(errno),
                           "unable to read entire file contents of '%s'", path);
    }
  }
  if (iree_status_is_ok(status)) {
    contents[file_size] = 0;  // NUL
    *out_contents = iree_make_byte_span(contents, file_size);
  } else {
    iree_allocator_free(allocator, contents);
  }
  fclose(file);
  IREE_TRACE_ZONE_END(z0);
  return status;
}

// NOTE: error handling is here just for better diagnostics: it is not tracking
// allocations correctly and will leak. Don't use this as an example for how to
// write robust code.
static iree_status_t iree_hal_executable_library_run(
    const iree_benchmark_def_t* benchmark_def,
    iree_benchmark_state_t* benchmark_state) {
  iree_allocator_t host_allocator = benchmark_state->host_allocator;

  // Register the loader used to load (or find) the executable.
  iree_hal_executable_loader_t* executable_loader = NULL;
  IREE_RETURN_IF_ERROR(iree_hal_executable_library_create_loader(
      host_allocator, &executable_loader));

  // Setup the specification used to perform the executable load.
  // This information is normally used to select the appropriate loader but in
  // this benchmark we only have a single one.
  iree_hal_executable_params_t executable_params;
  iree_hal_executable_params_initialize(&executable_params);
  executable_params.caching_mode =
      IREE_HAL_EXECUTABLE_CACHING_MODE_ALLOW_OPTIMIZATION |
      IREE_HAL_EXECUTABLE_CACHING_MODE_ALIAS_PROVIDED_DATA |
      IREE_HAL_EXECUTABLE_CACHING_MODE_DISABLE_VERIFICATION;
  executable_params.executable_format =
      iree_make_cstring_view(FLAG_executable_format);

  // Load the executable data.
  IREE_RETURN_IF_ERROR(iree_file_read_contents(
      FLAG_executable_file, host_allocator,
      (iree_byte_span_t*)&executable_params.executable_data));

  // Setup the layouts defining how each entry point is interpreted.
  // NOTE: we know for the embedded library loader that this is not required.
  // Other loaders may need it in which case it'll have to be provided.
  executable_params.executable_layout_count = 0;
  executable_params.executable_layouts = NULL;

  // Perform the load, which will fail if the executable cannot be loaded or
  // there was an issue with the layouts.
  iree_hal_executable_t* executable = NULL;
  IREE_RETURN_IF_ERROR(iree_hal_executable_loader_try_load(
      executable_loader, &executable_params, &executable));
  iree_hal_local_executable_t* local_executable =
      iree_hal_local_executable_cast(executable);

  // Allocate workgroup-local memory that each invocation can use.
  iree_byte_span_t local_memory = iree_make_byte_span(NULL, 0);
  iree_host_size_t local_memory_size =
      local_executable->dispatch_attrs
          ? local_executable->dispatch_attrs[FLAG_entry_point]
                    .local_memory_pages *
                IREE_HAL_WORKGROUP_LOCAL_MEMORY_PAGE_SIZE
          : 0;
  if (local_memory_size > 0) {
    IREE_RETURN_IF_ERROR(iree_allocator_malloc(
        host_allocator, local_memory_size, (void**)&local_memory.data));
    local_memory.data_length = local_memory_size;
  }

  // Allocate storage for buffers and populate them.
  // They only need to remain valid for the duration of the invocation and all
  // memory accessed by the invocation will come from here.
  iree_hal_allocator_t* heap_allocator = NULL;
  IREE_RETURN_IF_ERROR(iree_hal_allocator_create_heap(
      iree_make_cstring_view("benchmark"), host_allocator, host_allocator,
      &heap_allocator));
  iree_hal_buffer_view_t* buffer_views[IREE_HAL_LOCAL_MAX_TOTAL_BINDING_COUNT];
  void* binding_ptrs[IREE_HAL_LOCAL_MAX_TOTAL_BINDING_COUNT];
  size_t binding_lengths[IREE_HAL_LOCAL_MAX_TOTAL_BINDING_COUNT];
  for (iree_host_size_t i = 0; i < dispatch_params.binding_count; ++i) {
    IREE_RETURN_IF_ERROR(iree_hal_buffer_view_parse(
        dispatch_params.bindings[i], heap_allocator, &buffer_views[i]));
    iree_hal_buffer_t* buffer = iree_hal_buffer_view_buffer(buffer_views[i]);
    iree_device_size_t buffer_length =
        iree_hal_buffer_view_byte_length(buffer_views[i]);
    iree_hal_buffer_mapping_t buffer_mapping = {{0}};
    IREE_RETURN_IF_ERROR(iree_hal_buffer_map_range(
        buffer, IREE_HAL_MAPPING_MODE_PERSISTENT,
        IREE_HAL_MEMORY_ACCESS_READ | IREE_HAL_MEMORY_ACCESS_WRITE, 0,
        buffer_length, &buffer_mapping));
    binding_ptrs[i] = buffer_mapping.contents.data;
    binding_lengths[i] = (size_t)buffer_mapping.contents.data_length;
  }

  // Setup dispatch state.
  iree_hal_executable_dispatch_state_v0_t dispatch_state = {
      .workgroup_count = {{
          .x = FLAG_workgroup_count_x,
          .y = FLAG_workgroup_count_y,
          .z = FLAG_workgroup_count_z,
      }},
      .workgroup_size = {{
          .x = FLAG_workgroup_size_x,
          .y = FLAG_workgroup_size_y,
          .z = FLAG_workgroup_size_z,
      }},
      .push_constant_count = dispatch_params.push_constant_count,
      .push_constants = &dispatch_params.push_constants[0].ui32,
      .binding_count = dispatch_params.binding_count,
      .binding_ptrs = binding_ptrs,
      .binding_lengths = binding_lengths,
      .environment = &local_executable->environment,
  };

  // Execute benchmark the workgroup invocation.
  // Note that each iteration runs through the whole grid as it's important that
  // we are testing the memory access patterns: if we just ran the same single
  // tile processing the same exact region of memory over and over we are not
  // testing cache effects.
  int64_t dispatch_count = 0;
  while (iree_benchmark_keep_running(benchmark_state, /*batch_count=*/1)) {
    IREE_RETURN_IF_ERROR(iree_hal_local_executable_issue_dispatch_inline(
        local_executable, FLAG_entry_point, &dispatch_state, local_memory));
    ++dispatch_count;
  }

  // To get a total time per invocation we set the item count to the total
  // invocations dispatched. That gives us both total dispatch and single
  // invocation times in the reporter output.
  int64_t total_invocations =
      dispatch_count * dispatch_state.workgroup_count.x *
      dispatch_state.workgroup_count.y * dispatch_state.workgroup_count.z;
  iree_benchmark_set_items_processed(benchmark_state, total_invocations);

  // Deallocate buffers.
  for (iree_host_size_t i = 0; i < dispatch_params.binding_count; ++i) {
    iree_hal_buffer_view_release(buffer_views[i]);
  }
  iree_hal_allocator_release(heap_allocator);

  // Unload.
  iree_allocator_free(host_allocator,
                      (void*)executable_params.executable_data.data);
  iree_hal_executable_release(executable);
  iree_hal_executable_loader_release(executable_loader);

  return iree_ok_status();
}

int main(int argc, char** argv) {
  iree_flags_set_usage(
      "executable_library_benchmark",
      "Benchmarks a single entry point within an executable library.\n"
      "Executable libraries can be found in your temp path when compiling\n"
      "with `-iree-llvm-keep-linker-artifacts`. The parameters used can be\n"
      "inferred from the entry point `hal.interface` and dispatches to it.\n"
      "\n"
      "Note that this tool is intentionally low level: you must specify all\n"
      "of the push constant/binding parameters precisely as they are expected\n"
      "by the executable. `iree-benchmark-module` is the user-friendly\n"
      "benchmarking tool while this one favors direct access to the\n"
      "executables (bypassing all of the IREE VM, HAL APIs, task system,\n"
      "etc).\n"
      "\n"
      "Example --flagfile:\n"
      "  --executable_format=EX_ELF\n"
      "  --executable_file=iree/hal/local/elf/testdata/"
      "elementwise_mul_x86_64.so\n"
      "  --entry_point=0\n"
      "  --workgroup_count_x=1\n"
      "  --workgroup_count_y=1\n"
      "  --workgroup_count_z=1\n"
      "  --workgroup_size_x=1\n"
      "  --workgroup_size_y=1\n"
      "  --workgroup_size_z=1\n"
      "  --binding=4xf32=1,2,3,4\n"
      "  --binding=4xf32=100,200,300,400\n"
      "  --binding=4xf32=0,0,0,0);\n"
      "\n");

  iree_flags_parse_checked(IREE_FLAGS_PARSE_MODE_UNDEFINED_OK, &argc, &argv);
  iree_benchmark_initialize(&argc, argv);

  // TODO(benvanik): override these with our own flags.
  iree_benchmark_def_t benchmark_def = {
      .flags = IREE_BENCHMARK_FLAG_MEASURE_PROCESS_CPU_TIME |
               IREE_BENCHMARK_FLAG_USE_REAL_TIME,
      .time_unit = IREE_BENCHMARK_UNIT_NANOSECOND,
      .minimum_duration_ns = 0,
      .iteration_count = 0,
      .run = iree_hal_executable_library_run,
  };
  iree_benchmark_register(iree_make_cstring_view("dispatch"), &benchmark_def);

  iree_benchmark_run_specified();
  return 0;
}
