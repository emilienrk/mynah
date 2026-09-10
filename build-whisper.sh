#!/usr/bin/env bash
set -e

# Get absolute path to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
WHISPER_DIR="${SCRIPT_DIR}/whisper.cpp"
BUILD_DIR="${SCRIPT_DIR}/build-whisper"

echo "🔨 Compilation de whisper.cpp en lib statique avec Metal..."

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake "$WHISPER_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_USE_BF16=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu)

# cmake's configure_file writes package.json back into the submodule source tree,
# which dirties the working tree and trips the clean-tree guard in scripts/release.sh.
git -C "$WHISPER_DIR" checkout -- bindings/javascript/package.json 2>/dev/null || true

echo "✅ libwhisper.a compilée dans $BUILD_DIR/bin/"
