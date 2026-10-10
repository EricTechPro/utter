#!/bin/zsh
# Builds a self-contained whisper-cli (static, Metal embedded) into build/whisper-cli.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=v1.9.4
mkdir -p build/whisper-src
[[ -d build/whisper-src/src ]] || git clone --depth 1 --branch $VERSION https://github.com/ggml-org/whisper.cpp.git build/whisper-src/src
cmake -S build/whisper-src/src -B build/whisper-src/build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build/whisper-src/build --target whisper-cli -j 10
cp build/whisper-src/build/bin/whisper-cli build/whisper-cli
echo "Built build/whisper-cli"
