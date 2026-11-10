# Third-party libraries

Optional static libraries. They are not stored in this repository; two scripts put them here, and `build.sh`
links whichever it finds. When one is missing the matching feature compiles out (`#if canImport(...)`) and the
app either falls back to an installed ffmpeg or hides the option.

| Folder | Library | Licence | How to get it |
|---|---|---|---|
| `lame/` | LAME 3.100, MP3 encoder | LGPL 2.1 | `brew install lame`, then `Tools/vendor-lame.sh` |
| `webp/` | libwebp 1.4.0, WebP encoder | BSD 3-Clause | `Tools/fetch-webp.sh` downloads the release tarball from Google, verifies its SHA-256 and builds it with the bundled makefile |

If you distribute a binary that statically links LAME, the LGPL requires that recipients can relink against
another LAME build. Building from this source with `build.sh` satisfies that.
