#!/bin/zsh
# Builds whisper.cpp (static, Metal embedded): the library Utter links (build/whisper/{include,lib})
# and a self-contained whisper-cli (build/whisper-cli), used only if the library can't load the model.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=v1.9.4
mkdir -p build/whisper-src
[[ -d build/whisper-src/src ]] || git clone --depth 1 --branch $VERSION https://github.com/ggml-org/whisper.cpp.git build/whisper-src/src
cmake -S build/whisper-src/src -B build/whisper-src/build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
cmake --build build/whisper-src/build --target whisper whisper-cli -j 10
cp build/whisper-src/build/bin/whisper-cli build/whisper-cli

rm -rf build/whisper
mkdir -p build/whisper/include build/whisper/lib
cp build/whisper-src/src/include/whisper.h build/whisper-src/src/ggml/include/*.h build/whisper/include/
find build/whisper-src/build -name 'lib*.a' ! -name libcommon.a -exec cp {} build/whisper/lib/ \;
echo "Built build/whisper-cli and build/whisper"
