#!/bin/bash
set -e
cd ~/work/evan/llama.cpp

INSTALL_NAME="@rpath/llama.framework/llama"
IOS_MIN=16.0

build_for() {
    local build_dir="$1"
    local release_dir="$2"
    local sdk="$3"
    local archs="$4"
    local min_flag="$5"

    local libs=(
        "${build_dir}/src/${release_dir}/libllama.a"
        "${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
        "${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
    )

    local fw_root="${build_dir}/framework_v2/llama.framework"
    rm -rf "${fw_root}"
    mkdir -p "${fw_root}/Headers" "${fw_root}/Modules"

    # Copy headers
    cp include/llama.h ggml/include/ggml.h ggml/include/ggml-opt.h ggml/include/ggml-alloc.h ggml/include/ggml-backend.h ggml/include/ggml-metal.h ggml/include/ggml-cpu.h ggml/include/ggml-blas.h ggml/include/gguf.h "${fw_root}/Headers/"
    # Copy mtmd headers
    cp tools/mtmd/mtmd.h tools/mtmd/mtmd-helper.h tools/mtmd/mtmd-image.h tools/mtmd/mtmd-audio.h "${fw_root}/Headers/"

    # Modulemap with mtmd
    cat > "${fw_root}/Modules/module.modulemap" << EOF
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    header "mtmd.h"
    header "mtmd-helper.h"
    header "mtmd-image.h"
    header "mtmd-audio.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

    # Combine static libs
    local tmp="${build_dir}/tmp_v2"
    mkdir -p "${tmp}"
    xcrun libtool -static -o "${tmp}/combined.a" "${libs[@]}" 2>/dev/null

    # Link into a dynamic library
    local arch_flags=""
    for arch in $archs; do arch_flags="${arch_flags} -arch ${arch}"; done

    xcrun -sdk "${sdk}" clang++ \
        -dynamiclib \
        -isysroot $(xcrun -sdk "${sdk}" --show-sdk-path) \
        ${arch_flags} \
        ${min_flag} \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "${INSTALL_NAME}" \
        -Wl,-force_load,"${tmp}/combined.a" \
        -fobjc-link-runtime \
        -o "${fw_root}/llama"

    # Info.plist
    cat > "${fw_root}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>llama</string>
    <key>CFBundleIdentifier</key><string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>llama</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${IOS_MIN}</string>
</dict>
</plist>
EOF
    echo "Built: ${fw_root}"
}

# iOS device (arm64)
build_for "build-ios-device" "Release-iphoneos" "iphoneos" "arm64" "-mios-version-min=${IOS_MIN}"

# iOS sim (arm64 + x86_64)
build_for "build-ios-sim" "Release-iphonesimulator" "iphonesimulator" "arm64 x86_64" "-mios-simulator-version-min=${IOS_MIN}"

# Bundle into xcframework
rm -rf build-apple
mkdir -p build-apple
xcodebuild -create-xcframework \
    -framework "build-ios-device/framework_v2/llama.framework" \
    -framework "build-ios-sim/framework_v2/llama.framework" \
    -output build-apple/llama.xcframework

ls -la build-apple/llama.xcframework/
echo "DONE"
