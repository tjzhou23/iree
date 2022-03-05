// Copyright 2021 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "iree/hal/local/loaders/static_library_loader.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "iree/base/tracing.h"
#include "iree/hal/api.h"
#include "iree/hal/local/executable_environment.h"
#include "iree/hal/local/local_executable.h"
#include "iree/hal/local/local_executable_layout.h"

//===----------------------------------------------------------------------===//
// iree_hal_static_executable_t
//===----------------------------------------------------------------------===//

typedef struct iree_hal_static_executable_t {
  iree_hal_local_executable_t base;

  // Name used for the file field in tracy and debuggers.
  iree_string_view_t identifier;

  union {
    const iree_hal_executable_library_header_t** header;
    const iree_hal_executable_library_v0_t* v0;
  } library;

  iree_hal_local_executable_layout_t* layouts[];
} iree_hal_static_executable_t;

static const iree_hal_local_executable_vtable_t
    iree_hal_static_executable_vtable;

static iree_status_t iree_hal_static_executable_create(
    const iree_hal_executable_library_header_t** library_header,
    iree_host_size_t executable_layout_count,
    iree_hal_executable_layout_t* const* executable_layouts,
    const iree_hal_executable_import_provider_t import_provider,
    iree_allocator_t host_allocator, iree_hal_executable_t** out_executable) {
  IREE_ASSERT_ARGUMENT(library_header);
  IREE_ASSERT_ARGUMENT(!executable_layout_count || executable_layouts);
  IREE_ASSERT_ARGUMENT(out_executable);
  *out_executable = NULL;
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_static_executable_t* executable = NULL;
  iree_host_size_t total_size =
      sizeof(*executable) +
      executable_layout_count * sizeof(*executable->layouts);
  iree_status_t status =
      iree_allocator_malloc(host_allocator, total_size, (void**)&executable);
  if (iree_status_is_ok(status)) {
    iree_hal_local_executable_initialize(
        &iree_hal_static_executable_vtable, executable_layout_count,
        executable_layouts, &executable->layouts[0], host_allocator,
        &executable->base);
    executable->library.header = library_header;
    executable->identifier = iree_make_cstring_view((*library_header)->name);
    executable->base.dispatch_attrs = executable->library.v0->exports.attrs;
  }

  if (iree_status_is_ok(status)) {
    if (executable->library.v0->imports.count > 0) {
      status =
          iree_make_status(IREE_STATUS_UNIMPLEMENTED,
                           "static libraries do not support imports and should "
                           "directly link against the functions they require");
    }
  }

  if (iree_status_is_ok(status)) {
    *out_executable = (iree_hal_executable_t*)executable;
  } else {
    *out_executable = NULL;
  }
  IREE_TRACE_ZONE_END(z0);
  return status;
}

static void iree_hal_static_executable_destroy(
    iree_hal_executable_t* base_executable) {
  iree_hal_static_executable_t* executable =
      (iree_hal_static_executable_t*)base_executable;
  iree_allocator_t host_allocator = executable->base.host_allocator;
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_local_executable_deinitialize(
      (iree_hal_local_executable_t*)base_executable);
  iree_allocator_free(host_allocator, executable);

  IREE_TRACE_ZONE_END(z0);
}

static iree_status_t iree_hal_static_executable_issue_call(
    iree_hal_local_executable_t* base_executable, iree_host_size_t ordinal,
    const iree_hal_executable_dispatch_state_v0_t* dispatch_state,
    const iree_hal_vec3_t* workgroup_id, iree_byte_span_t local_memory) {
  iree_hal_static_executable_t* executable =
      (iree_hal_static_executable_t*)base_executable;
  const iree_hal_executable_library_v0_t* library = executable->library.v0;

  if (IREE_UNLIKELY(ordinal >= library->exports.count)) {
    return iree_make_status(IREE_STATUS_INVALID_ARGUMENT,
                            "entry point ordinal out of bounds");
  }

#if IREE_TRACING_FEATURES & IREE_TRACING_FEATURE_INSTRUMENTATION
  iree_string_view_t entry_point_name = iree_string_view_empty();
  if (library->exports.names != NULL) {
    entry_point_name = iree_make_cstring_view(library->exports.names[ordinal]);
  }
  if (iree_string_view_is_empty(entry_point_name)) {
    entry_point_name = iree_make_cstring_view("unknown_dylib_call");
  }
  IREE_TRACE_ZONE_BEGIN_EXTERNAL(
      z0, executable->identifier.data, executable->identifier.size, ordinal,
      entry_point_name.data, entry_point_name.size, NULL, 0);
  if (library->exports.tags != NULL) {
    const char* tag = library->exports.tags[ordinal];
    if (tag) {
      IREE_TRACE_ZONE_APPEND_TEXT(z0, tag);
    }
  }
#endif  // IREE_TRACING_FEATURES & IREE_TRACING_FEATURE_INSTRUMENTATION

  int ret = library->exports.ptrs[ordinal](dispatch_state, workgroup_id,
                                           local_memory.data);

  IREE_TRACE_ZONE_END(z0);

  return ret == 0 ? iree_ok_status()
                  : iree_make_status(
                        IREE_STATUS_INTERNAL,
                        "executable entry point returned catastrophic error %d",
                        ret);
}

static const iree_hal_local_executable_vtable_t
    iree_hal_static_executable_vtable = {
        .base =
            {
                .destroy = iree_hal_static_executable_destroy,
            },
        .issue_call = iree_hal_static_executable_issue_call,
};

//===----------------------------------------------------------------------===//
// iree_hal_static_library_loader_t
//===----------------------------------------------------------------------===//

typedef struct iree_hal_static_library_loader_t {
  iree_hal_executable_loader_t base;
  iree_allocator_t host_allocator;
  iree_host_size_t library_count;
  const iree_hal_executable_library_header_t** const libraries[];
} iree_hal_static_library_loader_t;

static const iree_hal_executable_loader_vtable_t
    iree_hal_static_library_loader_vtable;

iree_status_t iree_hal_static_library_loader_create(
    iree_host_size_t library_count,
    const iree_hal_executable_library_query_fn_t* library_query_fns,
    iree_hal_executable_import_provider_t import_provider,
    iree_allocator_t host_allocator,
    iree_hal_executable_loader_t** out_executable_loader) {
  IREE_ASSERT_ARGUMENT(!library_count || library_query_fns);
  IREE_ASSERT_ARGUMENT(out_executable_loader);
  *out_executable_loader = NULL;
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_hal_static_library_loader_t* executable_loader = NULL;
  iree_host_size_t total_size =
      sizeof(*executable_loader) +
      sizeof(executable_loader->libraries[0]) * library_count;
  iree_status_t status = iree_allocator_malloc(host_allocator, total_size,
                                               (void**)&executable_loader);
  if (iree_status_is_ok(status)) {
    iree_hal_executable_loader_initialize(
        &iree_hal_static_library_loader_vtable, import_provider,
        &executable_loader->base);
    executable_loader->host_allocator = host_allocator;
    executable_loader->library_count = library_count;

    // Default environment to enable initialization.
    iree_hal_executable_environment_v0_t environment;
    iree_hal_executable_environment_initialize(host_allocator, &environment);

    // Query and verify the libraries provided all match our expected version.
    // It's rare they won't, however static libraries generated with a newer
    // version of the IREE compiler that are then linked with an older version
    // of the runtime are difficult to spot otherwise.
    for (iree_host_size_t i = 0; i < library_count; ++i) {
      const iree_hal_executable_library_header_t* const* header_ptr =
          library_query_fns[i](IREE_HAL_EXECUTABLE_LIBRARY_LATEST_VERSION,
                               &environment);
      if (!header_ptr) {
        status = iree_make_status(
            IREE_STATUS_UNAVAILABLE,
            "failed to query library header for runtime version %d",
            IREE_HAL_EXECUTABLE_LIBRARY_LATEST_VERSION);
        break;
      }
      const iree_hal_executable_library_header_t* header = *header_ptr;
      IREE_TRACE_ZONE_APPEND_TEXT(z0, header->name);
      if (header->version > IREE_HAL_EXECUTABLE_LIBRARY_LATEST_VERSION) {
        status = iree_make_status(
            IREE_STATUS_FAILED_PRECONDITION,
            "executable does not support this version of the "
            "runtime (executable: %d, runtime: %d)",
            header->version, IREE_HAL_EXECUTABLE_LIBRARY_LATEST_VERSION);
        break;
      }
      memcpy((void*)&executable_loader->libraries[i], &header_ptr,
             sizeof(header_ptr));
    }
  }

  if (iree_status_is_ok(status)) {
    *out_executable_loader = (iree_hal_executable_loader_t*)executable_loader;
  } else {
    iree_allocator_free(host_allocator, executable_loader);
  }

  IREE_TRACE_ZONE_END(z0);
  return status;
}

static void iree_hal_static_library_loader_destroy(
    iree_hal_executable_loader_t* base_executable_loader) {
  iree_hal_static_library_loader_t* executable_loader =
      (iree_hal_static_library_loader_t*)base_executable_loader;
  iree_allocator_t host_allocator = executable_loader->host_allocator;
  IREE_TRACE_ZONE_BEGIN(z0);

  iree_allocator_free(host_allocator, executable_loader);

  IREE_TRACE_ZONE_END(z0);
}

static bool iree_hal_static_library_loader_query_support(
    iree_hal_executable_loader_t* base_executable_loader,
    iree_hal_executable_caching_mode_t caching_mode,
    iree_string_view_t executable_format) {
  return iree_string_view_equal(executable_format,
                                iree_make_cstring_view("static"));
}

static iree_status_t iree_hal_static_library_loader_try_load(
    iree_hal_executable_loader_t* base_executable_loader,
    const iree_hal_executable_params_t* executable_params,
    iree_hal_executable_t** out_executable) {
  iree_hal_static_library_loader_t* executable_loader =
      (iree_hal_static_library_loader_t*)base_executable_loader;

  // The executable data is just the name of the library.
  iree_string_view_t library_name = iree_make_string_view(
      (const char*)executable_params->executable_data.data,
      executable_params->executable_data.data_length);

  // Linear scan of the registered libraries; there's usually only one per
  // module (aka source model) and as such it's a small list and probably not
  // worth optimizing. We could sort the libraries list by name on loader
  // creation to perform a binary-search fairly easily, though, at the cost of
  // the additional code size.
  for (iree_host_size_t i = 0; i < executable_loader->library_count; ++i) {
    const iree_hal_executable_library_header_t* header =
        *executable_loader->libraries[i];
    if (iree_string_view_equal(library_name,
                               iree_make_cstring_view(header->name))) {
      return iree_hal_static_executable_create(
          executable_loader->libraries[i],
          executable_params->executable_layout_count,
          executable_params->executable_layouts,
          base_executable_loader->import_provider,
          executable_loader->host_allocator, out_executable);
    }
  }
  return iree_make_status(IREE_STATUS_NOT_FOUND,
                          "no static library with the name '%.*s' registered",
                          (int)library_name.size, library_name.data);
}

static const iree_hal_executable_loader_vtable_t
    iree_hal_static_library_loader_vtable = {
        .destroy = iree_hal_static_library_loader_destroy,
        .query_support = iree_hal_static_library_loader_query_support,
        .try_load = iree_hal_static_library_loader_try_load,
};
