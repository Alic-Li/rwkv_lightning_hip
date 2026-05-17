cmake_minimum_required(VERSION 3.24)
project(rwkv7_fast_v4 LANGUAGES CXX HIP)

list(PREPEND CMAKE_PREFIX_PATH /opt/rocm)
find_package(hip REQUIRED)
find_package(hipblas REQUIRED)
find_package(hipblaslt REQUIRED)
find_package(hiprand REQUIRED)
find_package(SQLite3 REQUIRED)
find_package(Drogon CONFIG QUIET)
if(NOT Drogon_FOUND)
  find_package(Drogon QUIET)
endif()

# Normalize SQLite target name across CMake/vcpkg variants on Windows.
if(TARGET SQLite3::SQLite3)
  set(RWKV_SQLITE_TARGET SQLite3::SQLite3)
elseif(TARGET SQLite::SQLite3)
  set(RWKV_SQLITE_TARGET SQLite::SQLite3)
else()
  add_library(RWKV_SQLITE_FALLBACK INTERFACE)
  if(SQLite3_INCLUDE_DIRS)
    target_include_directories(RWKV_SQLITE_FALLBACK INTERFACE ${SQLite3_INCLUDE_DIRS})
  endif()
  if(SQLite3_LIBRARIES)
    target_link_libraries(RWKV_SQLITE_FALLBACK INTERFACE ${SQLite3_LIBRARIES})
  elseif(SQLite3_LIBRARY)
    target_link_libraries(RWKV_SQLITE_FALLBACK INTERFACE ${SQLite3_LIBRARY})
  else()
    message(FATAL_ERROR "SQLite3 was found, but no linkable target or library variable was provided.")
  endif()
  set(RWKV_SQLITE_TARGET RWKV_SQLITE_FALLBACK)
endif()

option(RWKV7_FAST_V4_GC_SECTIONS "Enable section garbage collection to reduce binary size" ON)
option(RWKV7_FAST_V4_AUTO_STRIP "Strip the release binary after linking when possible" ON)
function(rwkv_configure_msvc_optimized_target target_name)
  target_compile_definitions(${target_name} PRIVATE
    $<$<NOT:$<CONFIG:Debug>>:NDEBUG>
  )
  target_compile_options(${target_name} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:/utf-8 /EHsc>
    $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CONFIG:Debug>>>:/O2>
    $<$<AND:$<COMPILE_LANGUAGE:HIP>,$<NOT:$<CONFIG:Debug>>>:/O2>
  )

  if(RWKV7_FAST_V4_MSVC_LTCG)
    target_compile_options(${target_name} PRIVATE
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CONFIG:Debug>>>:SHELL:/GL>
      $<$<AND:$<COMPILE_LANGUAGE:HIP>,$<NOT:$<CONFIG:Debug>>>:SHELL:/GL>
    )
  endif()
endfunction()

function(rwkv_configure_runtime_bundle target_name)
  if(APPLE)
    set(_rwkv_origin "@loader_path")
  elseif(UNIX)
    set(_rwkv_origin "$ORIGIN")
  else()
    set(_rwkv_origin "")
  endif()

  if(_rwkv_origin)
    set_target_properties(${target_name} PROPERTIES
      BUILD_RPATH "${_rwkv_origin};${_rwkv_origin}/lib"
      INSTALL_RPATH "${_rwkv_origin};${_rwkv_origin}/lib"
      BUILD_RPATH_USE_ORIGIN ON
    )
    if(UNIX AND NOT APPLE)
      target_link_options(${target_name} PRIVATE -Wl,--disable-new-dtags)
    endif()
  endif()

  add_custom_target(bundle_${target_name}
    COMMAND ${CMAKE_COMMAND}
      -DINPUT_FILE=$<TARGET_FILE:${target_name}>
      -DOUTPUT_DIR=${PROJECT_BINARY_DIR}/bundle/${target_name}
      -DLIB_OUTPUT_DIR=${PROJECT_BINARY_DIR}/bundle/${target_name}/lib
      -DCOPY_BINARY=ON
      -P ${PROJECT_SOURCE_DIR}/cmake/copy_runtime_deps.cmake
    DEPENDS ${target_name}
    VERBATIM
  )
endfunction()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_HIP_STANDARD 17)
set(CMAKE_HIP_STANDARD_REQUIRED ON)

set(RWKV7_FAST_SERVER_CORE_SOURCES
  hip/rwkv7_fast_v4.hip
  src/pth_archive.cpp
  src/pth_tensor.cpp
  src/rwkv_tokenizer.cpp
  src/utils/tokenizer.cpp
  src/rwkv_sampler.cpp
  src/rwkv_inference_engine.cpp
  src/rwkv_state_cache.cpp
  src/utils/sampling.hip
  hip/rwkv7_v3a_ops.hip
  hip/rwkv7_fast_ops_fp16.hip
  hip/rwkv7_wkv_fp16_v2.hip
  hip/rwkv7_wkv_fp32_v2.hip
)

set(RWKV7_FAST_HIP_SOURCES
  hip/rwkv7_fast_v4.hip
  src/utils/sampling.hip
  hip/rwkv7_v3a_ops.hip
  hip/rwkv7_fast_ops_fp16.hip
  hip/rwkv7_wkv_fp16_v2.hip
  hip/rwkv7_wkv_fp32_v2.hip
)

add_library(rwkv7_fast_backend_core STATIC
  ${RWKV7_FAST_SERVER_CORE_SOURCES}
)

target_include_directories(rwkv7_fast_backend_core PUBLIC src hip include)
target_compile_definitions(rwkv7_fast_backend_core PRIVATE _IO_FP16_ RWKV_SAMPLING_NO_TORCH)
target_link_libraries(rwkv7_fast_backend_core PUBLIC hip::host roc::hipblas roc::hipblaslt hip::hiprand ${RWKV_SQLITE_TARGET})
set_source_files_properties(${RWKV7_FAST_HIP_SOURCES} PROPERTIES LANGUAGE HIP)

if(MSVC)
  target_compile_definitions(rwkv7_fast_backend_core PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
  target_compile_options(rwkv7_fast_backend_core PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:/utf-8 /EHsc>
    $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CONFIG:Debug>>>:/O2>
  )
  rwkv_configure_msvc_optimized_target(rwkv7_fast_backend_core)
else()
  target_compile_options(rwkv7_fast_backend_core PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-O3>
  )
  if(RWKV7_FAST_V4_GC_SECTIONS)
    target_compile_options(rwkv7_fast_backend_core PRIVATE
      $<$<COMPILE_LANGUAGE:CXX>:-ffunction-sections -fdata-sections>
      $<$<COMPILE_LANGUAGE:HIP>:-ffunction-sections -fdata-sections>
    )
    target_link_options(rwkv7_fast_backend_core PRIVATE -Wl,--gc-sections)
  endif()
endif()

target_compile_options(rwkv7_fast_backend_core PRIVATE
  $<$<AND:$<COMPILE_LANGUAGE:HIP>,$<NOT:$<CONFIG:Debug>>>:-O3 -ffast-math>
)

if(Drogon_FOUND)
  add_executable(rwkv_lighting_hip
    src/rwkv_fast_server.cpp
    src/rwkv_api_service.cpp
  )
  target_link_libraries(rwkv_lighting_hip PRIVATE rwkv7_fast_backend_core Drogon::Drogon)
  target_include_directories(rwkv_lighting_hip PRIVATE src hip include)
  if(MSVC)
    target_compile_definitions(rwkv_lighting_hip PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
    target_compile_options(rwkv_lighting_hip PRIVATE /O2 /utf-8 /EHsc)
  else()
    target_compile_options(rwkv_lighting_hip PRIVATE -O3)
  endif()
  rwkv_configure_runtime_bundle(rwkv_lighting_hip)
else()
  message(WARNING "Drogon not found. 'rwkv_lighting_hip' target will not be built in this environment.")
endif()

if(RWKV7_FAST_V4_AUTO_STRIP AND CMAKE_STRIP AND NOT MSVC)
  if(TARGET rwkv_lighting_hip)
    message(STATUS "Skipping auto-strip for rwkv_lighting_hip to preserve embedded HIP code objects.")
  endif()
endif()
