cmake_minimum_required(VERSION 3.22)
project(utterwhisper C CXX)

set(CMAKE_BUILD_TYPE Release)
set(CMAKE_CXX_STANDARD 17)

# whisper.cpp (git submodule), CPU only, built into this one library.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
# Phones from about 2018 on (dot-product instructions make it several times faster).
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
add_subdirectory(whisper.cpp)

add_library(utterwhisper SHARED jni.cpp)
target_compile_options(utterwhisper PRIVATE -O3)
target_link_libraries(utterwhisper whisper log)
# Android 15+ devices with 16 KB memory pages need 16 KB-aligned LOAD segments.
target_link_options(utterwhisper PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")

# Same bridge for older phones without the ARMv8.2 dot-product instructions (they would crash
# on the fast build). A second, plain ARMv8 build of whisper.cpp; Kotlin picks one at runtime.
include(ExternalProject)
set(V8_DIR ${CMAKE_CURRENT_BINARY_DIR}/whisper_v8)
ExternalProject_Add(whisper_v8
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp
    BINARY_DIR ${V8_DIR}
    CMAKE_GENERATOR Ninja
    CMAKE_ARGS
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
        -DCMAKE_BUILD_TYPE=Release
        -DBUILD_SHARED_LIBS=OFF
        -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
        -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF
        -DGGML_CPU_ARM_ARCH=armv8-a
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS
        ${V8_DIR}/src/libwhisper.a
        ${V8_DIR}/ggml/src/libggml.a
        ${V8_DIR}/ggml/src/libggml-cpu.a
        ${V8_DIR}/ggml/src/libggml-base.a
)
add_library(utterwhisper_v8 SHARED jni.cpp)
add_dependencies(utterwhisper_v8 whisper_v8)
target_include_directories(utterwhisper_v8 PRIVATE whisper.cpp/include whisper.cpp/ggml/include)
target_compile_options(utterwhisper_v8 PRIVATE -O3)
target_link_libraries(utterwhisper_v8
    ${V8_DIR}/src/libwhisper.a
    ${V8_DIR}/ggml/src/libggml.a
    ${V8_DIR}/ggml/src/libggml-cpu.a
    ${V8_DIR}/ggml/src/libggml-base.a
    log m)
target_link_options(utterwhisper_v8 PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")
