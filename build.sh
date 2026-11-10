#!/bin/zsh
# Builds Clementine.app into dist/ with swiftc directly (no Xcode project, no SwiftPM).
# Usage: ./build.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")"
OPT="-O"
[[ "${1:-}" == "--debug" ]] && OPT="-Onone -g"

mkdir -p build build/modules
find Sources/Clementine -name '*.swift' | sort > build/sources.txt

# Optional static libraries (see ThirdParty/README.md). Each present one gets a Clang module and is linked in.
MODMAP=build/modules/module.modulemap
: > "$MODMAP"
LINK_FLAGS=()
if [[ -f ThirdParty/lame/lib/libmp3lame.a ]]; then
  printf 'module CLame [system] {\n  header "%s/ThirdParty/lame/include/lame/lame.h"\n  link "mp3lame"\n  export *\n}\n' "$PWD" >> "$MODMAP"
  LINK_FLAGS+=(-L "$PWD/ThirdParty/lame/lib")
  echo "with MP3 (LAME)"
fi
if [[ -f ThirdParty/webp/lib/libwebp.a ]]; then
  printf 'module CWebP [system] {\n  header "%s/ThirdParty/webp/include/webp/encode.h"\n  link "webp"\n  link "sharpyuv"\n  export *\n}\n' "$PWD" >> "$MODMAP"
  LINK_FLAGS+=(-L "$PWD/ThirdParty/webp/lib")
  echo "with WebP (libwebp)"
fi

swiftc -parse-as-library -swift-version 5 -suppress-warnings -target arm64-apple-macosx14.0 ${=OPT} \
  -I build/modules "${LINK_FLAGS[@]}" \
  -module-name Clementine @build/sources.txt -o build/Clementine

if [[ ! -f build/AppIcon.icns ]]; then
  swift Tools/make-icon.swift build
fi

APP="dist/Clementine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Clementine "$APP/Contents/MacOS/Clementine"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier com.francoismizrahi.Clementine "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "Built $APP"
