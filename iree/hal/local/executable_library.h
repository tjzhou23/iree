// Copyright 2020 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_HAL_LOCAL_EXECUTABLE_LIBRARY_H_
#define IREE_HAL_LOCAL_EXECUTABLE_LIBRARY_H_

// NOTE: this file is designed to be a standalone header: it is embedded in the
// compiler and must not take any dependencies on the runtime HAL code.
// Changes here will require changes to the compiler and must be versioned as if
// this was a schema: backwards-incompatible changes require version bumps or
// the ability to feature-detect at runtime.

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

//===----------------------------------------------------------------------===//
// Common utilities included to reduce dependencies
//===----------------------------------------------------------------------===//

// `restrict` keyword, not supported by some older compilers.
// We define our own macro in case dependencies use `restrict` differently.
#if defined(_MSC_VER) && _MSC_VER >= 1900
#define IREE_RESTRICT __restrict
#elif defined(_MSC_VER)
#define IREE_RESTRICT
#elif defined(__cplusplus)
#define IREE_RESTRICT __restrict__
#else
#define IREE_RESTRICT restrict
#endif  // _MSC_VER

//===----------------------------------------------------------------------===//
// Runtime feature support metadata
//===----------------------------------------------------------------------===//

// Defines a bitfield of features that the library requires or supports.
enum iree_hal_executable_library_feature_bits_t {
  IREE_HAL_EXECUTABLE_LIBRARY_FEATURE_NONE = 0u,
  // TODO(benvanik): declare features for debugging/coverage/printf/etc.
  // These will control which symbols are injected into the library at runtime.
};
typedef uint32_t iree_hal_executable_library_features_t;

// Defines a set of supported sanitizers that libraries may be compiled with.
// Loaders can use this declaration to check as to whether the library is
// compatible with the hosting environment for cases where the sanitizer
// requires host support.
typedef enum iree_hal_executable_library_sanitizer_kind_e {
  IREE_HAL_EXECUTABLE_LIBRARY_SANITIZER_NONE = 0,
  // Indicates the library is compiled to use AddressSanitizer:
  // https://clang.llvm.org/docs/AddressSanitizer.html
  // Equivalent compiler flag: -fsanitize=address
  IREE_HAL_EXECUTABLE_LIBRARY_SANITIZER_ADDRESS = 1,
  // Indicates the library is compiled to use MemorySanitizer:
  // https://clang.llvm.org/docs/MemorySanitizer.html
  // Equivalent compiler flag: -fsanitize=memory
  IREE_HAL_EXECUTABLE_LIBRARY_SANITIZER_MEMORY = 2,
  // Indicates the library is compiled to use ThreadSanitizer:
  // https://clang.llvm.org/docs/ThreadSanitizer.html
  // Equivalent compiler flag: -fsanitize=thread
  IREE_HAL_EXECUTABLE_LIBRARY_SANITIZER_THREAD = 3,
  // Indicates the library is compiled to use UndefinedBehaviorSanitizer:
  // https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
  // Equivalent compiler flag: -fsanitize=undefined
  IREE_HAL_EXECUTABLE_LIBRARY_SANITIZER_UNDEFINED = 4,

  IREE_HAL_EXECUTABLE_LIBRARY_SANITIZER_MAX_ENUM = INT32_MAX,
} iree_hal_executable_library_sanitizer_kind_t;

//===----------------------------------------------------------------------===//
// Versioning and interface querying
//===----------------------------------------------------------------------===//

typedef struct iree_hal_executable_environment_v0_t
    iree_hal_executable_environment_v0_t;

// Known valid version values.
typedef enum iree_hal_executable_library_version_e {
  // iree_hal_executable_library_v0_t is used as the API communication
  // structure.
  IREE_HAL_EXECUTABLE_LIBRARY_VERSION_0 = 0,

  IREE_HAL_EXECUTABLE_LIBRARY_VERSION_MAX_ENUM = INT32_MAX,
} iree_hal_executable_library_version_t;
static_assert(sizeof(iree_hal_executable_library_version_t) == 4, "uint32_t");

// The latest version of the library API; can be used to populate the
// iree_hal_executable_library_header_t::version when building libraries.
#define IREE_HAL_EXECUTABLE_LIBRARY_LATEST_VERSION \
  IREE_HAL_EXECUTABLE_LIBRARY_VERSION_0

// A header present at the top of all versions of the library API used by the
// runtime to ensure version compatibility.
typedef struct iree_hal_executable_library_header_t {
  // Version of the API this library was built with, which was likely the value
  // of IREE_HAL_EXECUTABLE_LIBRARY_LATEST_VERSION.
  iree_hal_executable_library_version_t version;

  // Name used for logging/diagnostics.
  const char* name;

  // Bitfield of features required/supported by this executable.
  iree_hal_executable_library_features_t features;

  // Which sanitizer the library is compiled to use, if any.
  // Libraries meant for use with a particular sanitizer will are only usable
  // with hosting code that is using the same sanitizer.
  iree_hal_executable_library_sanitizer_kind_t sanitizer;
} iree_hal_executable_library_header_t;

// Exported function from dynamic libraries for querying library information.
//
// The provided |max_version| is the maximum version the caller supports;
// callees must return NULL if their lowest available version is greater
// than the max version supported by the caller.
//
// The provided |environment| field contains information about the hosting
// execution environment that the executable may use to specialize its
// implementation, such as using specific imports or exporting
// architecture-specific dispatch routines. Some environmental properties may
// change per-invocation such as the CPU info when performing dispatches on
// heterogenous processors that may change over the lifetime of the program.
typedef const iree_hal_executable_library_header_t** (
    *iree_hal_executable_library_query_fn_t)(
    iree_hal_executable_library_version_t max_version,
    const iree_hal_executable_environment_v0_t* environment);

// Function name exported from dynamic libraries (pass to dlsym).
#define IREE_HAL_EXECUTABLE_LIBRARY_EXPORT_NAME \
  "iree_hal_executable_library_query"

//===----------------------------------------------------------------------===//
// IREE_HAL_EXECUTABLE_LIBRARY_VERSION_0
//===----------------------------------------------------------------------===//

// Function signature of imported functions for use in the executable.
// Each call takes opaque parameters as defined by the imported function.
// Both the compiler and the runtime must agree on the parameter format
// (including struct alignment and packing) and doing so is outside the scope
// of this API. In general one should only pass precisely what they need
// (pointers directly into buffers being manipulated, arguments, etc) and not
// try to replicate the dispatch structure (workgroup information and bindings)
// so that the imported functions can be versioned independently from this
// specification.
//
// Returns 0 on success and non-zero on failure. Failures will cause device loss
// and should only be used to communicate serious issues that should abort all
// execution within the current device. Buffer overflows are a good example of
// a useful failure though the HAL does not mandate that all overflows are
// caught and only that they are not harmful - clamping byte ranges and never
// returning a failure is sufficient.
typedef int (*iree_hal_executable_import_v0_t)(void* import_params);

// A thunk function used to call an import.
// All imports must be called through this function by passing the import
// function pointer as the first argument followed by the arguments of the
// import function itself.
typedef int (*iree_hal_executable_import_thunk_v0_t)(
    iree_hal_executable_import_v0_t fn_ptr, void* import_params);

// Declares imports available to the executable library at runtime.
// To enable linker isolation, ABI shimming, and import multi-versioning we use
// this import table exclusively and do not allow platform-level linking. If it
// were allowed the deployment situation gets significantly more complex as the
// libraries containing the imported symbols will differ on all platforms, will
// have the platform-dependent ABI (Windows, MacOS, etc), and may not be
// available at all (bare-metal).
//
// Static libraries may choose to still dynamically link against external
// symbols without using this table as in that scenario much of the above
// concerns do not apply: all code is being linked together into the same binary
// and symbol availability is known during build-time linking. Static linking
// also enables LTO to strip any import not used by any executables in contrast
// to the dynamic style elsewhere.
//
// Represented as a struct-of-arrays for more efficient packing and more
// locality during lookup. Each subarray - when not omitted and NULL - is
// indexed by import ordinal and has up to |count| entries.
typedef struct iree_hal_executable_import_table_v0_t {
  // Total number of imports in the table.
  uint32_t count;

  // Import symbol name encoding the name and whether it is weak.
  // Example: `mylib_some_fn_v2?`
  //   `mylib_...`:
  //     Prefix indicating the owner of the function; symbols have a global
  //     namespace and this is used to reduce collisions.
  //   `some_fn...`:
  //     Name of the function used to link to the imports available in the
  //     hosting executable.
  //   `..._v2`:
  //     Function-specified version number used to allow multiple versions to
  //     to be imported. For backward compatibility one could import both
  //     `some_fn_v1?` and `some_fn_v2?` and use whichever is available.
  //     Note that this is just a convention for the suffix and can be anything.
  //   `?`:
  //     Indicates when an import is optional. If the import of the specified
  //     version is not found the table entry will be NULL. When omitted if the
  //     import is unavailable loading will fail.
  //
  // The symbol table is sorted ascending alphabetical (by strcmp).
  const char* const* symbols;
} iree_hal_executable_import_table_v0_t;

// Maximum number of data fields in iree_hal_processor_v0_t.
// Executables must only reference the specified field count and this is allowed
// to grow at any time up to 32 uint64_t values (256B).
#define IREE_HAL_PROCESSOR_DATA_CAPACITY_V0 4

// Architecture-specific CPU information available to executables.
// This encodes a high-level identifier and zero or more fields of opaque data.
// It's encoded as a variable-length array of uint64_t values and if no
// additional data is provided is bitwise equivalent to a single 64-bit value.
// The intent is that this structure can be put in .rodata when there are no
// runtime features that need to be queried.
typedef struct iree_hal_processor_v0_t {
  // Simple identifier or set of flags that can be used to quickly test for
  // major architectural features without the need to walk the data table. The
  // format of the field is architecture-specific as by construction no value
  // will ever be used in a compiled binary from another architecture. This
  // allows us to simplify this interface as we can't for example load the same
  // executable library for both aarch64 on riscv32 and don't need to normalize
  // any of the fields across them both.
  //
  // The contents are opaque here as to support out-of-tree architectures. The
  // runtime code deriving the identifier/flags and providing it here is losely
  // coupled with the compiler code emitting checks based on the identifier and
  // only those two places ever need to change.
  uint32_t flags;

  // Bitfield indicating which data fields are valid.
  // Example: ...0101: fields data[0] and data[2] are valid.
  uint32_t data_valid;
  // Opaque architecture-specific encoding in 64-bit words.
  // This may represent a fixed-length data structure, a series of hardware
  // registers, or key-value pairs.
  // Only entries with the corresponding bit set in data_valid may be used.
  uint64_t data[IREE_HAL_PROCESSOR_DATA_CAPACITY_V0];
} iree_hal_processor_v0_t;
static_assert(sizeof(iree_hal_processor_v0_t) % sizeof(uint64_t) == 0,
              "8-byte alignment required");

// Defines the environment in which the executable is being used.
// Executables only have access to the information in this structure and must
// make all decisions based on it; this ensures executables are portable across
// operating environments (Linux, Mac, bare-metal, web, etc) by not having
// platform-specific syscalls and register query emulation.
typedef struct iree_hal_executable_environment_v0_t {
  // Optional architecture-specific CPU information.
  // In heterogenous processors this may represent any of the subarchitecture
  // types as it is derived from the core the calling thread is scheduled on.
  // Will be all zeros if unavailable.
  iree_hal_processor_v0_t processor;

  // Specialization constants available to the executable, if any.
  // Contains as many as declared in the library header.
  const uint32_t* constants;

  // Thunk function for calling imports. All calls must be made through this.
  iree_hal_executable_import_thunk_v0_t import_thunk;
  // Optional imported functions available for use within the executable.
  // Contains one entry per imported function. If an import was marked as weak
  // then the corresponding entry may be NULL.
  const iree_hal_executable_import_v0_t* imports;
} iree_hal_executable_environment_v0_t;

typedef union iree_hal_vec3_t {
  struct {
    uint32_t x;
    uint32_t y;
    uint32_t z;
  };
  uint32_t value[3];
} iree_hal_vec3_t;

// Read-only per-dispatch state passed to each workgroup in a dispatch.
typedef struct iree_hal_executable_dispatch_state_v0_t {
  // Total workgroup count for the dispatch. This is sourced from either the
  // original dispatch call (for iree_hal_command_buffer_dispatch) or the
  // indirection buffer (for iree_hal_command_buffer_dispatch_indirect).
  iree_hal_vec3_t workgroup_count;
  // Workgroup size chosen for the dispatch. For compilation modes where the
  // workgroup size is constant this may be ignored.
  iree_hal_vec3_t workgroup_size;

  // Total number of available 4 byte push constant values in |push_constants|.
  size_t push_constant_count;
  // |push_constant_count| values.
  const uint32_t* push_constants;

  // Total number of binding base pointers in |binding_ptrs| and
  // |binding_lengths|. The set is packed densely based on which bindings are
  // used (known at compile-time).
  size_t binding_count;
  // Base pointers to each binding buffer.
  void* const* binding_ptrs;
  // The length of each binding in bytes, 1:1 with |binding_ptrs|.
  const size_t* binding_lengths;

  // Logical processor identifier used to index into processor info fields.
  // Depending on the implementation this may be an ordinal, a bitfield, or an
  // opaque unique identifier.
  uint32_t processor_id;
  // Optional executable environment information.
  const iree_hal_executable_environment_v0_t* environment;
} iree_hal_executable_dispatch_state_v0_t;

// Function signature of exported executable entry points.
// The same |dispatch_state| is passed to all workgroups in a dispatch while
// |workgroup_id| and |local_memory| will vary for each workgroup.
//
// If a non-zero value was specified for |local_memory_page| then scratch memory
// will be available for use by the invocation of at least the size specified.
// This memory is transient and exclusive to the workgroup. The provided pointer
// may be NULL if no workgroup local memory was requested and otherwise will
// point to memory of the size specified.
//
// Returns 0 on success and non-zero on failure. Failures will cause device loss
// and should only be used to communicate serious issues that should abort all
// execution within the current device. Buffer overflows are a good example of
// a useful failure though the HAL does not mandate that all overflows are
// caught and only that they are not harmful - clamping byte ranges and never
// returning a failure is sufficient.
typedef int (*iree_hal_executable_dispatch_v0_t)(
    const iree_hal_executable_dispatch_state_v0_t* dispatch_state,
    const iree_hal_vec3_t* workgroup_id, void* local_memory);

// Bytes per page of workgroup local memory.
// This is chosen to match the common page size of devices.
#define IREE_HAL_WORKGROUP_LOCAL_MEMORY_PAGE_SIZE 4096

// Attributes for exported dispatch functions defining how they are to be
// executed. 0 defaults are well-specified and the entire attributes table may
// be omitted if no dispatch functions require these fields.
typedef struct iree_hal_executable_dispatch_attrs_v0_t {
  // Number of IREE_HAL_WORKGROUP_LOCAL_MEMORY_PAGE_SIZE byte pages (or 0)
  // indicating how much workgroup local memory is required for the dispatch.
  // This is the size of the buffer referenced by the `local_memory` argument.
  uint16_t local_memory_pages;
  // Must be 0. May be used in the future for flags controlling the dispatch
  // behavior/synchronization requirements.
  uint16_t reserved;
} iree_hal_executable_dispatch_attrs_v0_t;
static_assert(sizeof(iree_hal_executable_dispatch_attrs_v0_t) == 4, "uint32_t");

// A table of exported functions arranged as a struct-of-arrays for more
// efficient packing and faster lookup. Each subarray - when not omitted and
// NULL - is indexed by export ordinal and has up to |count| entries.
typedef struct iree_hal_executable_export_table_v0_t {
  // Total number of exports in the table.
  uint32_t count;

  // Function pointers for each exported entry point.
  const iree_hal_executable_dispatch_v0_t* ptrs;

  // Optional table of attributes 1:1 with ptrs.
  // Omitting the table entirely means that no exports need workgroup local
  // memory (or whatever else we pack into the attributes).
  const iree_hal_executable_dispatch_attrs_v0_t* attrs;

  // Optional table of export function entry point names 1:1 with ptrs.
  // These names are only used for tracing/debugging and can be omitted to save
  // binary size.
  const char* const* names;

  // Optional table of entry point tags 1:1 with ptrs.
  // Used to describe the entry point in a human-readable format useful for
  // verbose logging. The string values, when present, may be attached to
  // tracing/debugging events related to the entry point.
  const char* const* tags;
} iree_hal_executable_export_table_v0_t;

// A table declaring the executable-level constants that can be used to
// specialize the executable behavior.
typedef struct iree_hal_executable_constant_table_v0_t {
  // Total number of constants in the table.
  uint32_t count;
  // We could add more metadata here if we wanted to enable reflection.
} iree_hal_executable_constant_table_v0_t;

// Structure used for v0 library interfaces.
// The entire structure is designed to be read-only and able to live embedded in
// the binary .rdata section.
//
// The information held within the structure is not cached by the runtime.
// Implementations may choose to heap allocate this structure and modify its
// members at runtime so long as they observe the thread-safety guarantees.
// For example, a JIT may default all exports to JIT thunk functions and then
// atomically swap them out for the translated function pointers as they are
// available.
typedef struct iree_hal_executable_library_v0_t {
  // Version/metadata header.
  // Will have a version of IREE_HAL_EXECUTABLE_LIBRARY_VERSION_0.
  const iree_hal_executable_library_header_t* header;

  // Table of imported functions available to functions in the executable.
  iree_hal_executable_import_table_v0_t imports;

  // Table of exported functions from the executable.
  iree_hal_executable_export_table_v0_t exports;

  // Table of executable-level constants.
  iree_hal_executable_constant_table_v0_t constants;
} iree_hal_executable_library_v0_t;

#endif  // IREE_HAL_LOCAL_EXECUTABLE_LIBRARY_H_
