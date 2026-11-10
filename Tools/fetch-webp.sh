#!/bin/zsh
# Downloads libwebp from Google's release server, builds the static libraries with the bundled makefile (no cmake),
# and installs headers + libs into ThirdParty/webp so build.sh links WebP encoding into Clementine.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${WEBP_VERSION:-1.4.0}"
URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${VERSION}.tar.gz"
mkdir -p build/webp-src
cd build/webp-src
if [[ ! -f "libwebp-${VERSION}.tar.gz" ]]; then
  echo "Downloading ${URL}"
  curl -fL -o "libwebp-${VERSION}.tar.gz" "$URL"
fi
if [[ "$VERSION" == "1.4.0" ]]; then
  EXPECTED="61f873ec69e3be1b99535634340d5bde750b2e4447caa1db9f61be3fd49ab1e5"
  ACTUAL="$(shasum -a 256 "libwebp-${VERSION}.tar.gz" | cut -d' ' -f1)"
  [[ "$ACTUAL" == "$EXPECTED" ]] || { echo "Checksum mismatch for libwebp-${VERSION}.tar.gz"; exit 1; }
fi
rm -rf "libwebp-${VERSION}"
tar -xzf "libwebp-${VERSION}.tar.gz"
cd "libwebp-${VERSION}"
make -f makefile.unix -j"$(sysctl -n hw.ncpu)" src/libwebp.a sharpyuv/libsharpyuv.a EXTRA_FLAGS="-O3 -DWEBP_HAVE_NEON -arch arm64"
cd ../../..
mkdir -p ThirdParty/webp/include/webp ThirdParty/webp/lib
cp "build/webp-src/libwebp-${VERSION}/src/webp/"*.h ThirdParty/webp/include/webp/
cp "build/webp-src/libwebp-${VERSION}/src/libwebp.a" "build/webp-src/libwebp-${VERSION}/sharpyuv/libsharpyuv.a" ThirdParty/webp/lib/
cp "build/webp-src/libwebp-${VERSION}/COPYING" ThirdParty/webp/LICENSE-BSD.txt
echo "libwebp ${VERSION} installed into ThirdParty/webp. Now run ./build.sh"
