# Install script for directory: /Users/erictech/Desktop/Utter/android/app/src/main/cpp/whisper.cpp

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/opt/homebrew/share/android-commandlinetools/ndk/27.2.12479018/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-objdump")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/src/libwhisper.a")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include" TYPE FILE FILES "/Users/erictech/Desktop/Utter/android/app/src/main/cpp/whisper.cpp/include/whisper.h")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/src/libparakeet.a")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include" TYPE FILE FILES "/Users/erictech/Desktop/Utter/android/app/src/main/cpp/whisper.cpp/include/parakeet.h")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/whisper" TYPE FILE FILES
    "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/whisper-config.cmake"
    "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/whisper-config-version.cmake"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig" TYPE FILE FILES "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/whisper.pc")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/parakeet" TYPE FILE FILES
    "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/parakeet-config.cmake"
    "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/parakeet-config-version.cmake"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig" TYPE FILE FILES "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/parakeet.pc")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for each subdirectory.
  include("/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/ggml/cmake_install.cmake")
  include("/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/src/cmake_install.cmake")

endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/Users/erictech/Desktop/Utter/android/app/.cxx/RelWithDebInfo/633h311h/arm64-v8a/whisper.cpp/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
