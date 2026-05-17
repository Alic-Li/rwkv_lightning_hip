cmake_minimum_required(VERSION 3.24)

if(NOT DEFINED INPUT_FILE OR INPUT_FILE STREQUAL "")
  message(FATAL_ERROR "INPUT_FILE is required")
endif()
if(NOT DEFINED OUTPUT_DIR OR OUTPUT_DIR STREQUAL "")
  message(FATAL_ERROR "OUTPUT_DIR is required")
endif()
if(NOT DEFINED LIB_OUTPUT_DIR OR LIB_OUTPUT_DIR STREQUAL "")
  set(LIB_OUTPUT_DIR "${OUTPUT_DIR}")
endif()

set(COPY_BINARY "${COPY_BINARY}")
if(COPY_BINARY STREQUAL "")
  set(COPY_BINARY OFF)
endif()

get_filename_component(INPUT_FILE "${INPUT_FILE}" ABSOLUTE)
get_filename_component(OUTPUT_DIR "${OUTPUT_DIR}" ABSOLUTE)
get_filename_component(LIB_OUTPUT_DIR "${LIB_OUTPUT_DIR}" ABSOLUTE)

file(MAKE_DIRECTORY "${OUTPUT_DIR}")
file(MAKE_DIRECTORY "${LIB_OUTPUT_DIR}")

if(COPY_BINARY)
  file(COPY "${INPUT_FILE}" DESTINATION "${OUTPUT_DIR}")
endif()

file(GET_RUNTIME_DEPENDENCIES
  EXECUTABLES "${INPUT_FILE}"
  RESOLVED_DEPENDENCIES_VAR resolved_deps
  UNRESOLVED_DEPENDENCIES_VAR unresolved_deps
  POST_EXCLUDE_REGEXES
    "^api-ms-win-"
    "^ext-ms-win-"
)

function(should_skip_dep dep out_var)
  set(skip FALSE)
  if(WIN32)
    if(dep MATCHES "^[A-Za-z]:[/\\\\]Windows[/\\\\](System32|SysWOW64)[/\\\\]")
      set(skip TRUE)
    endif()
  elseif(UNIX)
    if(dep MATCHES "^/lib.*/ld-linux[^/]*\\.so(\\.[^/]+)*$")
      set(skip TRUE)
    elseif(dep MATCHES "^/usr/lib.*/ld-linux[^/]*\\.so(\\.[^/]+)*$")
      set(skip TRUE)
    elseif(dep MATCHES "^/lib.*/lib(c|m|pthread|dl|rt|util|resolv|nsl|anl)\\.so(\\.[^/]+)*$")
      set(skip TRUE)
    elseif(dep MATCHES "^/usr/lib.*/lib(c|m|pthread|dl|rt|util|resolv|nsl|anl)\\.so(\\.[^/]+)*$")
      set(skip TRUE)
    endif()
  endif()
  set(${out_var} "${skip}" PARENT_SCOPE)
endfunction()

function(copy_dep_with_symlinks dep destination_dir)
  get_filename_component(dep_name "${dep}" NAME)
  file(REAL_PATH "${dep}" dep_real)
  file(COPY_FILE "${dep_real}" "${destination_dir}/${dep_name}" ONLY_IF_DIFFERENT)
endfunction()

function(copy_optional_file_if_exists src dest)
  if(EXISTS "${src}")
    get_filename_component(dest_dir "${dest}" DIRECTORY)
    file(MAKE_DIRECTORY "${dest_dir}")
    file(COPY_FILE "${src}" "${dest}" ONLY_IF_DIFFERENT)
  endif()
endfunction()

function(copy_globbed_files source_root destination_root)
  set(glob_patterns ${ARGN})
  if(NOT EXISTS "${source_root}")
    return()
  endif()

  file(MAKE_DIRECTORY "${destination_root}")

  set(matched_files)
  foreach(glob_pattern IN LISTS glob_patterns)
    file(GLOB pattern_files "${source_root}/${glob_pattern}")
    list(APPEND matched_files ${pattern_files})
  endforeach()
  list(REMOVE_DUPLICATES matched_files)

  foreach(source_file IN LISTS matched_files)
    if(NOT EXISTS "${source_file}")
      continue()
    endif()
    get_filename_component(source_name "${source_file}" NAME)
    file(COPY_FILE "${source_file}" "${destination_root}/${source_name}" ONLY_IF_DIFFERENT)
  endforeach()
endfunction()

function(copy_tensile_runtime_data destination_dir)
  if(NOT UNIX)
    return()
  endif()

  set(rocblas_src_root "/opt/rocm/lib/rocblas/library")
  set(hipblaslt_src_root "/opt/rocm/lib/hipblaslt/library")

  set(rocblas_dst_root "${destination_dir}/rocblas/library")
  set(hipblaslt_dst_root "${destination_dir}/hipblaslt/library")
  file(MAKE_DIRECTORY "${rocblas_dst_root}")
  file(MAKE_DIRECTORY "${hipblaslt_dst_root}")

  # Copy each library's own Tensile assets instead of mirroring rocBLAS data into
  # hipBLASLt. The lazy .dat manifests also depend on matching .co/.hsaco objects.
  copy_globbed_files(
    "${rocblas_src_root}"
    "${rocblas_dst_root}"
    "TensileLibrary_lazy_gfx110*.dat"
    "TensileLibrary_*gfx110*.dat"
    "TensileLibrary_*gfx110*.co"
    "TensileLibrary_*fallback.dat"
    "TensileLibrary_*fallback_gfx110*.hsaco"
    "Kernels.so-000-gfx110*.hsaco"
  )

  copy_globbed_files(
    "${hipblaslt_src_root}"
    "${hipblaslt_dst_root}"
    "TensileLibrary_lazy_gfx110*.dat"
    "TensileLibrary_*gfx110*.dat"
    "TensileLibrary_*gfx110*.co"
    "Kernels.so-000-gfx110*.hsaco"
    "extop_gfx110*.co"
    "TensileLiteLibrary_lazy_Mapping.dat"
  )
endfunction()

foreach(dep IN LISTS resolved_deps)
  should_skip_dep("${dep}" skip_dep)
  if(skip_dep)
    continue()
  endif()
  copy_dep_with_symlinks("${dep}" "${LIB_OUTPUT_DIR}")
endforeach()

copy_tensile_runtime_data("${LIB_OUTPUT_DIR}")

file(GLOB copied_loader_files
  "${LIB_OUTPUT_DIR}/ld-linux*.so"
  "${LIB_OUTPUT_DIR}/ld-linux*.so.*"
  "${LIB_OUTPUT_DIR}/ld-*.so"
  "${LIB_OUTPUT_DIR}/ld-*.so.*"
)
if(copied_loader_files)
  file(REMOVE ${copied_loader_files})
endif()
file(REMOVE
  "${LIB_OUTPUT_DIR}/ld-linux-x86-64.so.2"
  "${LIB_OUTPUT_DIR}/ld-linux.so.2"
)

if(unresolved_deps)
  list(JOIN unresolved_deps ", " unresolved_text)
  message(WARNING "Unresolved runtime dependencies for ${INPUT_FILE}: ${unresolved_text}")
endif()
