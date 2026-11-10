#!/bin/zsh
# Copies LAME's static library and header from Homebrew into ThirdParty/lame so build.sh links MP3 encoding.
# LAME is LGPL 2.1 and is therefore not stored in this repository.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh"; exit 1
fi
PREFIX="$(brew --prefix lame 2>/dev/null || true)"
if [[ -z "$PREFIX" || ! -f "$PREFIX/lib/libmp3lame.a" ]]; then
  echo "LAME is not installed. Run: brew install lame"; exit 1
fi
mkdir -p ThirdParty/lame/include/lame ThirdParty/lame/lib
cp "$PREFIX/include/lame/lame.h" ThirdParty/lame/include/lame/
cp "$PREFIX/lib/libmp3lame.a" ThirdParty/lame/lib/
[[ -f "$PREFIX/COPYING" ]] && cp "$PREFIX/COPYING" ThirdParty/lame/LICENSE-LGPL.txt
echo "LAME installed into ThirdParty/lame. Now run ./build.sh"
