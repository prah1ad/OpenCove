#!/bin/bash
# Builds OpenCove.app with just the Xcode Command Line Tools (xcode-select --install).
# Usage: ./build.sh          -> native arch
#        UNIVERSAL=1 ./build.sh -> arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OpenCove.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  xcrun -sdk macosx swiftc -parse-as-library -swift-version 5 -O \
    -target "$1-apple-macos13.0" Sources/*.swift -o "$2"
}

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  compile arm64 build/OpenCove-arm64
  compile x86_64 build/OpenCove-x86_64
  lipo -create build/OpenCove-arm64 build/OpenCove-x86_64 -output "$APP/Contents/MacOS/OpenCove"
  rm build/OpenCove-arm64 build/OpenCove-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/OpenCove"
fi

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP  ->  open $APP"
