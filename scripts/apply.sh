#!/usr/bin/env bash
# apply.sh — clone llama.cpp + overlay our patches + build the iOS-only XCFramework + build the iOS app.
# Idempotent. Safe to re-run; it skips work that's already done.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/llama.cpp"
LLAMA_REF="${LLAMA_REF:-master}"

GGUF_REPO="unsloth/gemma-4-E2B-it-GGUF"
MODEL_FILE="gemma-4-E2B-it-Q4_K_M.gguf"
MMPROJ_FILE="mmproj-F16.gguf"

# 1) Clone llama.cpp
if [[ ! -d "${WORK_DIR}/.git" ]]; then
    echo "==> cloning llama.cpp..."
    git clone --depth 1 --branch "${LLAMA_REF}" https://github.com/ggml-org/llama.cpp.git "${WORK_DIR}"
else
    echo "==> llama.cpp already cloned at ${WORK_DIR}"
fi

# 2) Overlay patched files
echo "==> overlaying patched files"
SWIFTUI="${WORK_DIR}/examples/llama.swiftui"
cp "${REPO_ROOT}/patches/LibLlama.swift"        "${SWIFTUI}/llama.cpp.swift/LibLlama.swift"
cp "${REPO_ROOT}/patches/LlamaState.swift"      "${SWIFTUI}/llama.swiftui/Models/LlamaState.swift"
cp "${REPO_ROOT}/patches/ContentView.swift"     "${SWIFTUI}/llama.swiftui/UI/ContentView.swift"
cp "${REPO_ROOT}/patches/build-xcframework.sh"  "${WORK_DIR}/build-xcframework.sh"
chmod +x "${WORK_DIR}/build-xcframework.sh"

# 3) Download GGUFs into iOS app's Resources/models/
echo "==> downloading GGUFs (skip if cached)"
MODELS_DIR="${SWIFTUI}/llama.swiftui/Resources/models"
mkdir -p "${MODELS_DIR}"
for f in "${MODEL_FILE}" "${MMPROJ_FILE}"; do
    if [[ ! -s "${MODELS_DIR}/${f}" ]]; then
        echo "    fetching ${f}..."
        curl -L --fail "https://huggingface.co/${GGUF_REPO}/resolve/main/${f}" -o "${MODELS_DIR}/${f}"
    else
        echo "    ${f} already present ($(du -sh "${MODELS_DIR}/${f}" | awk '{print $1}'))"
    fi
done

# 4) Build the iOS-only XCFramework with mtmd
echo "==> building iOS XCFramework with mtmd (this takes ~5-10 min on M-series)"
cd "${WORK_DIR}"

if [[ ! -d build-ios-device ]]; then
    cmake -B build-ios-device -G Xcode \
        -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=ON \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS_DEFAULT=ON \
        -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
fi
cmake --build build-ios-device --config Release -- -quiet

if [[ ! -d build-ios-sim ]]; then
    cmake -B build-ios-sim -G Xcode \
        -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=ON \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS_DEFAULT=ON \
        -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
fi
cmake --build build-ios-sim --config Release -- -quiet

bash "${REPO_ROOT}/scripts/build_ios_xcframework.sh"

# 5) Build the iOS app for generic iOS device (unsigned)
echo "==> building llama.swiftui.app for generic/iOS"
cd "${SWIFTUI}"
rm -rf build_ios
xcodebuild -project llama.swiftui.xcodeproj -scheme llama.swiftui \
    -destination "generic/platform=iOS" \
    -derivedDataPath ./build_ios \
    -skipMacroValidation -skipPackagePluginValidation \
    -configuration Debug \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH="${SWIFTUI}/build_ios/Build/Products/Debug-iphoneos/llama.swiftui.app"
echo
echo "==================================================================="
echo " Done. App built at:"
echo "   ${APP_PATH}"
echo
echo " Bundle size: $(du -sh "${APP_PATH}" | awk '{print $1}')"
echo
echo " Next step: open the project in Xcode, set up signing, deploy:"
echo "   open ${WORK_DIR}/examples/llama.swiftui/llama.swiftui.xcodeproj"
echo "==================================================================="
