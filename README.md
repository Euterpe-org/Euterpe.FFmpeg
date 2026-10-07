# Euterpe.FFmpeg

Minimal static FFmpeg and ffprobe builds for Euterpe.Press, for Windows and
Linux x86_64 and macOS on Apple silicon. CI builds them from pinned sources with
only the components Press uses, tests them, and publishes each build as a
release.

## Licence

The scripts in this repository are LGPL-2.1-or-later, see [`LICENSE`](LICENSE).

The binaries are FFmpeg built without `--enable-gpl` or `--enable-nonfree`, so
they are LGPL-2.1-or-later too; the libraries linked in (dav1d, SVT-AV1, Opus,
libwebp, zlib) are under BSD-style licences. Each release carries the licences
in `NOTICE-<platform>.txt` and the FFmpeg source the binaries were built from.
