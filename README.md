# Clementine

A menu-bar file utility for macOS: drag any file, hold a modifier key, and a radial wheel appears under the cursor with everything you can do to that file. Drop on a petal and the result lands next to the original. The interaction is inspired by Tangerine for Mac; the code is an independent implementation.

- **⇧ while dragging: Convert.** Images, audio, video, PDF, Word, RTF, HTML, Markdown and text to other formats.
- **⌘ while dragging: Tools.** Compress, resize, strip metadata, rotate, OCR, read QR codes, merge, split or compress PDFs, mute or speed up video, extract audio, zip, checksum.
- **⌃ while dragging: Actions.** Copy path, copy files, reveal, open a terminal there, AirDrop, move to Trash, or park the files in a **Float**, a small always-on-top shelf you can drag out of later.

No Dock icon, no sign-in, no purchase, no network. Everything runs on the frameworks that ship with macOS (ImageIO, AVFoundation, AudioToolbox, PDFKit, Vision, TextKit, Quartz filters), plus two optional static libraries: LAME for MP3 and libwebp for WebP, each put in place by a script. If Homebrew's `ffmpeg` is installed it is still borrowed for WebM, MKV and OGG.

## Build and install

Requires macOS 14 or later on Apple silicon and the Xcode Command Line Tools. No Xcode project, no SwiftPM, no dependencies.

```bash
./build.sh
```

This compiles with `swiftc`, draws the app icon, assembles `dist/Clementine.app` and ad-hoc signs it. MP3 and WebP output are optional and their libraries are not stored in the repository. Before building, run `Tools/vendor-lame.sh` (after `brew install lame`) for MP3 and `Tools/fetch-webp.sh` for WebP; the latter downloads the libwebp release tarball from Google's server, checks its SHA-256 and builds it with the bundled makefile, no cmake needed. `build.sh` prints which of the two it linked, and without them the app simply hides those formats unless an installed ffmpeg provides them. To install:

```bash
cp -R dist/Clementine.app /Applications/ && open /Applications/Clementine.app
```

The first launch shows a welcome window with a sample image to drag. Turn on "Launch at login" there or in Settings. The first time Clementine writes into Desktop, Documents or Downloads, macOS asks once for folder access.

## How it works

| Piece | File | What it does |
|---|---|---|
| Drag detection | `Sources/Clementine/Wheel/DragMonitor.swift` | Global mouse monitors notice the button going down; a 40 ms timer then watches the system drag pasteboard for file URLs and reads `NSEvent.modifierFlags`. No Accessibility permission needed. |
| The wheel | `Wheel/WheelController.swift`, `WheelView.swift`, `WheelGeometry.swift` | A borderless, non-activating `NSPanel` placed under the cursor. Its content view is an AppKit dragging destination that maps the cursor angle to a petal; SwiftUI draws the ring. Switching modifiers mid-drag swaps the wheel in place. |
| Catalog | `Engine/OperationCatalog.swift` | Decides which petals show for a set of files (all images, all audio, mixed, folders…) and wires each petal to a converter. Up to 8 petals per wheel. |
| Converters | `Converters/*.swift` | `ImageConverter` (ImageIO), `AudioConverter` (AVAssetReader/Writer), `VideoConverter` (AVAssetExportSession, compositions, GIF via ImageIO), `PDFConverter` (PDFKit, Quartz "Reduce File Size" filter, Vision OCR), `DocumentConverter` (TextKit import/export, Markdown bridge, PDF pagination), `Tools` (OCR, barcodes, zip/extract, SHA-256). |
| Output rules | `Core/Output.swift` | Results go beside the source, written first to a hidden `.clementine-<uuid>` sibling and then renamed to a unique name (`photo.jpg`, `photo 2.jpg`, `photo Compressed.jpg`). |
| Jobs and HUD | `Engine/JobCenter.swift` | Background queue, progress per job, a small floating HUD with a Reveal button, a sound on completion. |
| Floats | `Float/FloatWindow.swift` | Floating shelves: drop to add, drag rows out one at a time or all at once, Quick Look, context menu. |
| Picker | `UI/PickerWindow.swift` | Non-wheel entry point: "Convert Files…" in the menu, `open -a Clementine file`, or double-clicking the app. |
| Settings | `Core/Settings.swift`, `UI/SettingsWindow.swift` | Modifier per wheel, reveal/sound options, image quality, video preset, terminal app, launch at login. |

## Command line

The same engine is scriptable, which is also how it is tested:

```bash
dist/Clementine.app/Contents/MacOS/Clementine --list photo.heic
dist/Clementine.app/Contents/MacOS/Clementine --run convert.image.jpg photo.heic
dist/Clementine.app/Contents/MacOS/Clementine --render-wheel wheel.png tools photo.jpg
```

## What is available

**Images** (jpg, png, heic, avif, tiff, gif, bmp, webp, svg in): convert to JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, PDF and WebP (once libwebp is fetched; lossless WebP at quality 100); compress; resize to 1920 or 800 px; remove metadata (lossless for JPEG and PNG: the compressed pixel data is copied untouched, only EXIF/XMP/IPTC/text chunks go, colour profile stays); rotate; OCR to text; read QR/barcodes to clipboard; combine into one PDF.

**Audio**: M4A (AAC), FLAC, Apple Lossless, WAV, AIFF, CAF and Opus natively through AudioToolbox (Opus lands in a CAF container unless ffmpeg provides `.opus`), MP3 through the linked LAME (VBR quality 2, about 190 kbps); OGG needs ffmpeg. Inputs AudioToolbox cannot open are decoded through AVFoundation first. Tools: compress to 64 kbps, mono, 1.5× and 0.5× speed with pitch preserved.

**Video**: MP4 (H.264), MP4 HEVC, MOV, M4V, GIF preview, audio-only M4A; WebM and MKV with ffmpeg. Tools: compress to 720p, target size, mute, extract audio, snapshot frame, GIF, 2× and 0.5× speed, extract embedded subtitles to SRT (tx3g/WebVTT tracks natively, other containers through ffmpeg). Hardware encoders only, so exports are fast.

**PDF**: pages to PNG or JPEG, to Word, RTF or text (OCR kicks in for scanned pages), merge, split, compress, rotate, OCR. OCR runs Vision twice: a fast pass locates the text, an accurate pass reads a crop of that region, which is what makes small tables on large pages readable.

**Documents** (docx, doc, rtf, rtfd, html, md, txt, csv, json, source, epub): PDF, Word, RTF, HTML, text, Markdown and EPUB. The EPUB writer is native (EPUB 3, chapters split at top-level headings, embedded images carried over, language detected); EPUB input is read in spine order. Word files are rendered to PDF by Pages when it is installed, with TextKit as the fallback.

**Office files** (pages, numbers, key, xlsx, xls, pptx, ppt, and OpenDocument when Microsoft Office is present): converted by the installed apps over Apple Events, so fidelity is whatever Pages, Numbers, Keynote, Word, Excel or PowerPoint produce. Pages gives PDF, Word, EPUB, RTF and text; Numbers gives PDF, Excel and CSV; Keynote gives PDF, PowerPoint and slide images; the Office apps give PDF. The first use of each app shows macOS's "Clementine wants to control Pages" prompt, which you accept once. An app that was not running is quit again afterwards. Note that an ad-hoc signed build gets a new identity on every rebuild, so the prompt comes back after you rebuild; it stops once you stop rebuilding.

**Subtitles** (srt, vtt): SRT to WebVTT, WebVTT to SRT, plain transcript. Styling tags are stripped.

**Target size** (images and videos, Tools wheel): choose a budget such as 500 KB or 25 MB. Images get a binary search on JPEG or HEIC quality, then downscaling if allowed; videos are re-encoded as H.264 with the bitrate that fits, shrinking the frame when the budget is tight, with one corrective pass if the first result overshoots.

**Anything**: zip, extract zip/tar, SHA-256, duplicate, and all Actions.

**Editors** (Tools wheel, open a window instead of running at once; Save goes through the same job pipeline and naming rules):

- *Crop & Adjust* for images: rotate, flip, crop with handles and aspect presets, exposure, brightness, contrast, saturation, vibrance, warmth, sharpness, live preview on a 1600 px proxy and a full-resolution export that keeps EXIF/GPS/IPTC when asked. Saves `name Edited.ext`.
- *Redact* for images: draw regions, pixelate, blur or solid fill, find faces (Vision), find every occurrence of a word or number, or all text; burned in at full resolution with all metadata removed. Saves `name Redacted.ext`.
- *Organize PDF*: thumbnails of one or several PDFs, drag to reorder, rotate, delete, reverse, append more PDFs, undo. Saves `name Organized.pdf` or `Merged.pdf`.
- *Annotate* for images: arrows, lines, boxes, ellipses, freehand pen, highlighter, text, numbered steps and a 2× magnifier bubble, eight colours, four stroke widths, select/move/resize, undo. One Core Graphics renderer draws both the live canvas and the full-resolution export. Saves `name Annotated.ext`.
- *Trim & Crop* for video: player with thumbnail timeline, in/out handles, Set In/Out at the playhead (I and O), play selection, optional crop on a still frame with aspect presets, remove audio. Trim alone is a passthrough export with no re-encoding; cropping renders through a video composition with the configured quality preset. Saves `name Trimmed.mp4`, `name Cropped.mp4` and so on.
- *Collage* (two or more images): auto grid, 2 or 3 columns, one row or one column; fill or fit cells; gap, white/black/transparent background, output width up to 4800 px; live preview. Saves `Collage.jpg` next to the first image.
- *Visualizer* (audio): renders an H.264 MP4 at 1280×720, 1080×1080 or 1080×1920 with FFT-driven bars, mirrored bars or a line, in one of eight colours, over a dark gradient or an image of your choice, with the file name as a title. Audio is muxed as AAC. Saves `name Visualizer.mp4`.
- *Metadata* (images): edit title, description, caption, keywords, creator, copyright, credit, camera make and model, lens, software, dates, city, country, user comment and GPS coordinates, or remove GPS; a disclosure shows every property ImageIO can read. JPEG, PNG and TIFF are rewritten losslessly through ImageIO's metadata updater (pixel data untouched); HEIC and others are re-encoded at high quality. Saves `name Metadata.ext`; "Remove all metadata" is also one click away.
- *Trim & Bleep* for audio: waveform, in/out handles, bleep ranges drawn on the waveform or dropped at the playhead (B), undo. Bleeps mute the source and overlay a 1 kHz tone through an audio mix. WAV, AIFF, CAF and FLAC stay in their format; everything else becomes 256 kbps AAC in M4A.

## Testing

`Tools/smoke-test.sh` runs the engine over a fixture set (image, audio, video, PDF, Markdown, HTML, folder) through the command-line mode and prints each output. `Clementine --selftest-editors photo.jpg doc.pdf` exercises the three editor export pipelines without a window, `--snapshot-editor image|redact|pdfOrganizer <file> out.png` renders an editor window to a PNG, `--target-size <bytes> <files>` runs the target-size engine, and `--office-scripts <dir>` writes the generated AppleScripts so `osacompile` can check them against the installed dictionaries. Passing a video and an audio file as third and fourth arguments to `--selftest-editors` also exercises annotate, video trim/crop and audio trim/bleep. `--selftest-phase4 <image> <audio> <markdown>` covers EPUB write and read, collage, lossless metadata rewrite, MP3 and the visualizer. The drag wheel itself has to be tried by hand: drag a file in Finder, hold ⇧, and drop on a petal.

## Credits and scope

The modifier-plus-drag wheel is inspired by Tangerine for Mac, a commercial app built around that interaction. Clementine is an independent implementation written from scratch. It contains no code, assets or binaries from Tangerine and is not affiliated with it. If you want a polished, supported product, buy Tangerine.

Not included here: a sandboxed App Store build, bundled ffmpeg or ExifTool, audio normalization and video timeline redaction. The editor scaffold in `Sources/Clementine/Editors/EditorManager.swift` is the starting point for new editors.

## License

MIT, see [LICENSE](LICENSE). The optional libraries keep their own licences: LAME is LGPL 2.1 and libwebp is BSD 3-Clause, see [ThirdParty/README.md](ThirdParty/README.md).
