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
