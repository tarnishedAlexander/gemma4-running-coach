#!/usr/bin/env bash
# litert-lm/apply.sh — scaffold + build the GemmaCoach iOS app via XcodeGen.
# No sudo. Idempotent.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) Ensure xcodegen is available
if ! command -v xcodegen >/dev/null 2>&1; then
    if [[ ! -x "${HOME}/.local/bin/xcodegen" ]]; then
        echo "==> downloading XcodeGen 2.45.4 (one-time)"
        TMP="$(mktemp -d)"
        curl -sL -o "${TMP}/xcodegen.zip" \
            "https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip"
        unzip -oq "${TMP}/xcodegen.zip" -d "${TMP}/xg"
        mkdir -p "${HOME}/.local/bin"
        ln -sf "${TMP}/xg/xcodegen/bin/xcodegen" "${HOME}/.local/bin/xcodegen"
    fi
    export PATH="${HOME}/.local/bin:${PATH}"
fi
xcodegen --version

# 2) Generate Xcode project
cd "${HERE}/ios-app"
xcodegen generate

# 3) Build for generic iOS device (unsigned)
echo "==> building GemmaCoach.app for generic/iOS"
rm -rf build_ios
xcodebuild -project GemmaCoach.xcodeproj -scheme GemmaCoach \
    -destination "generic/platform=iOS" \
    -derivedDataPath ./build_ios \
    -skipMacroValidation -skipPackagePluginValidation \
    -configuration Debug \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build

APP="build_ios/Build/Products/Debug-iphoneos/GemmaCoach.app"

cat <<EOF

==========================================================================
 Done. App built at:
   ${HERE}/ios-app/${APP}

 Bundle size: $(du -sh "${APP}" | awk '{print $1}')
 Note: Gemma 4 model NOT bundled in the .app — first launch downloads
       gemma-4-E2B-it.litertlm (~2.6 GB) from Hugging Face into the app's
       Documents directory. After first download, airplane mode is fine.

 To deploy to a physical iPhone (16 Pro recommended):
   open ${HERE}/ios-app/GemmaCoach.xcodeproj
 Then in Xcode:
   1. Signing & Capabilities → tick Automatically manage signing
   2. Pick your Team
   3. (Bundle ID may need to be made unique to you)
   4. Plug iPhone, select destination, ⌘R
==========================================================================
EOF
