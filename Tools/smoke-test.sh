#!/bin/zsh
# Smoke-tests the engine through the headless CLI. Usage: Tools/smoke-test.sh [workdir]
# Needs ffmpeg on PATH only to generate the audio/video fixtures.
set -uo pipefail
cd "$(dirname "$0")/.."
C="$PWD/dist/Clementine.app/Contents/MacOS/Clementine"
[[ -x "$C" ]] || { echo "Build first: ./build.sh"; exit 1; }
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/clementine-smoke.XXXX")}"
mkdir -p "$W" && cd "$W"
echo "fixtures in $W"
# Fixtures
swift - <<'SWIFT' 2>/dev/null
import AppKit
let c = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 100, y: 100, width: 200, height: 120))
let img = c.makeImage()!
for (name, type) in [("photo.jpg", "public.jpeg"), ("image.png", "public.png")] {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: name) as CFURL, type as CFString, 1, nil)!
    let props: [String: Any] = [kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "TestCam", kCGImagePropertyTIFFArtist as String: "Someone"]]
    CGImageDestinationAddImage(d, img, props as CFDictionary); CGImageDestinationFinalize(d)
}
SWIFT
printf '# Title\n\nSome **bold** text.\n\n- a\n- b\n' > notes.md
printf '<html><body><h1>Hi</h1><p>Paragraph</p></body></html>' > page.html
mkdir -p folder && echo hi > folder/a.txt
FF=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
if [[ -x "$FF" ]]; then
  "$FF" -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=2" -c:a aac tone.m4a
  "$FF" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=320x180:rate=30:duration=2" -f lavfi -i "sine=frequency=440:duration=2" -c:v h264_videotoolbox -c:a aac -pix_fmt yuv420p -shortest clip.mp4
fi
pass=0; fail=0
run() { # op files...
  local op=$1; shift
  if out=$("$C" --run "$op" "$@" 2>&1); then pass=$((pass+1)); echo "PASS $op -> $(echo "$out" | head -1 | xargs -0 basename 2>/dev/null | tr -d '\n')"
  else fail=$((fail+1)); echo "FAIL $op: $(echo "$out" | tail -1)"; fi
}
run convert.image.png photo.jpg
run convert.image.heic photo.jpg
run convert.image.pdf photo.jpg image.png
run tool.image.strip photo.jpg
run tool.image.compress photo.jpg
run tool.image.resize800 photo.jpg
run tool.image.rotate photo.jpg
run convert.doc.pdf notes.md
run convert.doc.docx notes.md
run convert.doc.pdf page.html
run convert.doc.docx page.html
run convert.pdf.png notes.pdf
run tool.pdf.ocr notes.pdf
run convert.pdf.merge notes.pdf page.pdf
run tool.pdf.split Merged.pdf
run tool.pdf.compress Merged.pdf
run any.zip folder
run convert.archive.extract folder.zip
run tool.any.checksum notes.md
if [[ -f tone.m4a ]]; then
  run convert.audio.wav tone.m4a
  run convert.audio.aiff tone.m4a
  run tool.audio.mono tone.m4a
  run convert.video.mov clip.mp4
  run convert.video.gif clip.mp4
  run tool.video.mute clip.mp4
  run tool.video.snapshot clip.mp4
  run tool.video.speed2 clip.mp4
fi
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
