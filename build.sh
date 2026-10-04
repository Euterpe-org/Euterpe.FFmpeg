#!/usr/bin/env bash
# Builds the minimal FFmpeg and ffprobe that Euterpe.Press embeds.
#
#   bash build.sh [output directory, default out]
#
# Windows: an MSYS2 MINGW64 shell with the packages the workflow installs;
# everything is linked statically. Linux: the workflow's manylinux_2_28
# container; every library is linked statically except glibc, so the result
# runs on glibc 2.28 or later.
#
# Every input that decides what comes out is pinned in this file: the versions,
# the commit or SHA-256 each source must match, and the component lists. CI
# caches the result on a hash of this file, so changing any of it rebuilds.
#
# Writes, into the output directory:
#   ffmpeg, ffprobe          (.exe on Windows)
#   NOTICE.txt               the licence of FFmpeg and of every library linked in
#   ffmpeg-<version>.tar.xz  the FFmpeg source these were built from
#
# The component lists are what Press runs, not a general-purpose FFmpeg:
#
#   inputs   music downloaded from music sites and apps: mp3, m4a (AAC, ALAC),
#            aac, flac, opus, ogg (Vorbis, Opus), wav (integer and float PCM);
#            background videos downloaded from video sites or exported from
#            editing software: mp4, mov, m4v, mkv, webm, avi carrying H.264,
#            H.265, AV1, VP9, VP8, MPEG-4 Part 2 or ProRes (their audio is
#            dropped, so no decoders for it); covers: png, jpg, static webp, gif.
#   outputs  Opus in Ogg; WebP through the webp muxer, libwebp for a still
#            cover and libwebp_anim for an animated GIF; SVT-AV1 in MP4, or a
#            conforming source stream copied into MP4; f32le PCM down a pipe.
#   checks   `-f null` with no codec chosen falls back to wrapped_avframe and
#            pcm_s16le, so the decode check needs both; frames are read back
#            as rawvideo.
#
# Two configures from one source. ffprobe only demuxes and decodes, so it is
# built without encoders, muxers, filters or swscale; otherwise SVT-AV1 alone
# would be linked into it for nothing.
#
# Most of the time goes to configure steps, which start one small process after
# another, and starting a process is slow under MSYS2. Steps that do not depend
# on each other therefore run side by side: the five libraries, then ffmpeg and
# ffprobe. Each writes its own log under $WORK/logs.
set -euo pipefail

FFMPEG_VERSION=9.0.2
FFMPEG_COMMIT=946fcce07b6dcd0331c8cc609192aeff5e1924f8
# FFmpeg, SVT-AV1, dav1d, libwebp and Opus come from their GitHub repositories
# (the GitLab hosts refuse CI runners, and git.ffmpeg.org drops long clones),
# so each checkout is held to the commit its tag stands for.
SVTAV1_VERSION=v4.2.0
SVTAV1_COMMIT=9292ec8e32bce26f781f277ec8739b53426c4300
DAV1D_VERSION=1.5.4
DAV1D_COMMIT=54706fc6bc0cdecab7e9593974a4039cc038fca7
LIBWEBP_VERSION=v1.6.0
LIBWEBP_COMMIT=4fa21912338357f89e4fd51cf2368325b59e9bd9
OPUS_VERSION=1.6.1
OPUS_COMMIT=22244de5a79bd1d6d623c32e72bf1954b56235be
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16

# FFmpeg's own `av1` decoder is hardware-only, so libdav1d decodes AV1 and the
# native one is left out. JPEG pictures are decoded by `mjpeg`; `webp` selects
# vp8 and `mpeg4` selects h263. mp3float is the decoder FFmpeg picks for MP3.
DECODERS=mp3float,aac,alac,flac,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,\
h264,hevc,libdav1d,vp9,vp8,mpeg4,prores,\
png,mjpeg,webp,gif
DEMUXERS=mp3,mov,aac,flac,ogg,wav,matroska,avi,\
image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,gif
PARSERS=mpegaudio,aac,flac,opus,vorbis,h264,hevc,av1,vp9,vp8,mpeg4video,\
png,mjpeg,webp,gif
# libavformat uses extract_extradata while probing; the MP4 muxer selects the
# others it needs itself.
BSFS=extract_extradata
ENCODERS=libopus,libsvtav1,libwebp,libwebp_anim,pcm_f32le,pcm_s16le,wrapped_avframe,rawvideo
MUXERS=ogg,mp4,webp,pcm_f32le,null,rawvideo
# Named by Press: atrim, asetpts, crop, scale, format, fps. Inserted by
# FFmpeg itself: aresample/aformat for -ar/-ac and sample formats, scale/format
# for -pix_fmt, trim/atrim for output -ss/-t, transpose/hflip/vflip/rotate for
# autorotation, null/anull as graph glue.
FILTERS=aresample,aformat,anull,atrim,asetpts,crop,scale,format,fps,null,trim,setpts,\
transpose,hflip,vflip,rotate

out=$(realpath -m "${1:-out}")
work=${WORK:-/tmp/euterpe-ffmpeg}
prefix=$work/prefix
zlib=$work/zlib-$ZLIB_VERSION
jobs=$(nproc)

case "$(uname -s)-$(uname -m)" in
    MINGW64_NT*-x86_64)
        platform=windows exe=.exe cmake_system=Windows
        # Fully static: no MinGW runtime DLL may travel with the executables.
        link=(--extra-ldflags="-L$prefix/lib -flto=$jobs -O3" --extra-libs="-lstdc++ -static -static-libgcc -static-libstdc++")
        ;;
    Linux-x86_64)
        platform=linux exe= cmake_system=Linux
        # Static but for glibc, which is not meant to be linked statically.
        link=(--extra-ldflags="-L$prefix/lib -static-libgcc -flto=$jobs -O3" --extra-libs="-lm -lpthread")
        ;;
    *)
        echo "error: build in an MSYS2 MINGW64 shell or on x86_64 Linux" >&2
        exit 1
        ;;
esac

# A Windows shell can omit PROCESSOR_ARCHITECTURE. CMake then detects an empty
# CPU name and Opus silently omits its SIMD implementations. The target was
# checked above; name it explicitly for all CMake libraries. Keep the x86_64
# baseline and runtime dispatch, rather than requiring the build host's CPU.
cmake_common=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME="$cmake_system"
    -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION:BOOL=ON
)

rm -rf "$work"
mkdir -p "$work/logs" "$prefix/lib/pkgconfig" "$out"

# Runs each named function in the background with its own log, then waits for
# all of them. A function runs under `set -e` this way (inside an `if` it would
# not), and one that fails has the end of its log printed.
together() {
    local name failed=0
    local -A pids=()
    for name in "$@"; do
        "$name" > "$work/logs/$name.log" 2>&1 &
        pids[$name]=$!
    done
    for name in "$@"; do
        if wait "${pids[$name]}"; then
            echo "== $name done"
        else
            echo "error: $name failed; the end of $work/logs/$name.log:" >&2
            tail -n 80 "$work/logs/$name.log" >&2
            failed=1
        fi
    done
    return $failed
}

clone() { # url tag commit directory
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$2" "$1" "$4"
    local got
    got=$(git -C "$4" rev-parse HEAD)
    if [ "$got" != "$3" ]; then
        echo "error: $1 $2 is $got here, expected $3" >&2
        exit 1
    fi
}

fetch() { # url sha256 file
    curl -fsSL --retry 3 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c -
}

# Optimizations can also be silently disabled by feature detection. Check the
# generated configuration, not just the switches passed to the build system.
require_lines() { # file, then exact lines that must be present
    local file=$1 expected
    shift
    for expected in "$@"; do
        grep -Fxq -- "$expected" "$file" || {
            echo "error: $file is missing $expected" >&2
            exit 1
        }
    done
}

# PNG's deflate; --disable-autodetect would otherwise leave it out.
build_zlib() {
    fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
        "$ZLIB_SHA256" "$work/zlib.tar.gz"
    tar xzf "$work/zlib.tar.gz" -C "$work"
    if [ "$platform" = windows ]; then
        make -C "$zlib" -f win32/Makefile.gcc -j"$jobs" \
            CFLAGS="-O3 -flto" AR=gcc-ar libz.a
        install -D -m644 "$zlib/libz.a" "$prefix/lib/libz.a"
        install -D -m644 -t "$prefix/include" "$zlib/zlib.h" "$zlib/zconf.h"
        # win32/Makefile.gcc writes no .pc, and FFmpeg asks pkg-config for zlib.
        cat > "$prefix/lib/pkgconfig/zlib.pc" <<EOF
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: $ZLIB_VERSION
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
    else
        (cd "$zlib" && CFLAGS="-O3 -flto" AR=gcc-ar RANLIB=gcc-ranlib \
            ./configure --static --prefix="$prefix" && make -j"$jobs" install)
    fi
}

build_opus() {
    clone https://github.com/xiph/opus.git "v$OPUS_VERSION" "$OPUS_COMMIT" "$work/opus"
    # Stack protector and fortify make opus link libssp on MinGW, which a static
    # FFmpeg would then have to find too.
    # FLOAT_APPROX is also the upstream Autoconf default on x86_64 (IEEE 754).
    # It uses Opus's own approximations, not the unsupported -ffast-math mode.
    cmake -S "$work/opus" -B "$work/opus-build" -G Ninja "${cmake_common[@]}" \
        -DOPUS_BUILD_SHARED_LIBRARY=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_BUILD_PROGRAMS=OFF \
        -DOPUS_DISABLE_INTRINSICS=OFF \
        -DOPUS_X86_MAY_HAVE_SSE=ON \
        -DOPUS_X86_MAY_HAVE_SSE2=ON \
        -DOPUS_X86_MAY_HAVE_SSE4_1=ON \
        -DOPUS_X86_MAY_HAVE_AVX2=ON \
        -DOPUS_X86_PRESUME_SSE4_1=OFF \
        -DOPUS_X86_PRESUME_AVX2=OFF \
        -DOPUS_FLOAT_APPROX=ON \
        -DOPUS_FAST_MATH=OFF \
        -DOPUS_STACK_PROTECTOR=OFF \
        -DOPUS_FORTIFY_SOURCE=OFF
    require_lines "$work/opus-build/CMakeCache.txt" \
        'OPUS_X86_MAY_HAVE_SSE:BOOL=ON' \
        'OPUS_X86_MAY_HAVE_SSE2:BOOL=ON' \
        'OPUS_X86_MAY_HAVE_SSE4_1:BOOL=ON' \
        'OPUS_X86_MAY_HAVE_AVX2:BOOL=ON'
    cmake --build "$work/opus-build" --target install
}

build_dav1d() {
    clone https://github.com/videolan/dav1d.git "$DAV1D_VERSION" "$DAV1D_COMMIT" "$work/dav1d"
    meson setup "$work/dav1d/build" "$work/dav1d" \
        --prefix="$prefix" \
        --libdir=lib \
        --buildtype=release \
        --default-library=static \
        -Db_lto=true \
        -Denable_asm=true \
        -Denable_tools=false \
        -Denable_tests=false
    require_lines "$work/dav1d/build/config.h" '#define HAVE_ASM 1'
    ninja -C "$work/dav1d/build" install
}

build_svtav1() {
    clone https://github.com/AOMediaCodec/SVT-AV1.git "$SVTAV1_VERSION" "$SVTAV1_COMMIT" "$work/svt"
    cmake -S "$work/svt" -B "$work/svt/build" -G Ninja "${cmake_common[@]}" \
        -DCOMPILE_C_ONLY=OFF \
        -DENABLE_AVX512=ON \
        -DSVT_AV1_LTO=ON \
        -DNATIVE=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_APPS=OFF \
        -DBUILD_DEC=OFF
    require_lines "$work/svt/build/CMakeCache.txt" \
        'COMPILE_C_ONLY:BOOL=OFF' 'ENABLE_AVX512:BOOL=ON'
    cmake --build "$work/svt/build" --target install
}

build_libwebp() {
    clone https://github.com/webmproject/libwebp.git "$LIBWEBP_VERSION" "$LIBWEBP_COMMIT" "$work/libwebp"
    # The libraries alone. libwebp_anim needs libwebpmux as well as libwebp (and
    # the libsharpyuv it requires), found through the .pc files this installs.
    cmake -S "$work/libwebp" -B "$work/libwebp/build" -G Ninja "${cmake_common[@]}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWEBP_ENABLE_SIMD=ON \
        -DWEBP_USE_THREAD=ON \
        -DWEBP_BUILD_ANIM_UTILS=OFF \
        -DWEBP_BUILD_CWEBP=OFF \
        -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF \
        -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF \
        -DWEBP_BUILD_LIBWEBPMUX=ON \
        -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF
    require_lines "$work/libwebp/build/CMakeCache.txt" \
        'WEBP_HAVE_FLAG_SSE2:INTERNAL=1' \
        'WEBP_HAVE_FLAG_SSE41:INTERNAL=1' \
        'WEBP_HAVE_FLAG_AVX2:INTERNAL=1'
    cmake --build "$work/libwebp/build" --target install
}

echo "== zlib $ZLIB_VERSION, opus $OPUS_VERSION, dav1d $DAV1D_VERSION, SVT-AV1 $SVTAV1_VERSION, libwebp $LIBWEBP_VERSION"
together build_zlib build_opus build_dav1d build_svtav1 build_libwebp

echo "== FFmpeg $FFMPEG_VERSION"
clone https://github.com/FFmpeg/FFmpeg.git "n$FFMPEG_VERSION" "$FFMPEG_COMMIT" "$work/ffmpeg"
common=(
    --disable-everything
    --disable-autodetect
    --disable-network
    --disable-doc
    --disable-shared
    --enable-static
    # Keep startup cheap for Press's short conversions. LTO is applied to the
    # -O3 libraries at link time. FFmpeg's own --enable-lto would also pass -Os
    # to the linker and override the libraries' optimization level.
    --enable-small
    --enable-optimizations
    --cpu=x86-64
    --enable-runtime-cpudetect
    --enable-asm
    --enable-x86asm
    --disable-ffplay
    --disable-avdevice
    --enable-zlib
    --enable-libdav1d
    --enable-decoder="$DECODERS"
    --enable-demuxer="$DEMUXERS"
    --enable-parser="$PARSERS"
    --enable-bsf="$BSFS"
    --enable-protocol=file,pipe
    --pkg-config-flags=--static
    --extra-cflags="-I$prefix/include"
    "${link[@]}"
)

# configure quietly DISABLES a component whose dependency is missing (the PNG
# codec without zlib, say) and the resulting binary still starts and lists the
# rest. Refuse to build anything short of the list asked for.
require() { # kind (DECODER, ...), comma-separated names
    local kind=$1 name missing=()
    local -a names
    IFS=, read -ra names <<< "$2"
    for name in "${names[@]}"; do
        grep -qx "#define CONFIG_${name^^}_$kind 1" config_components.h || missing+=("$name")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "error: configure left out ${kind,,}s: ${missing[*]}" >&2
        exit 1
    fi
}

# "Static" is a claim about the result, so it is checked on the result: an
# executable that needs a library the user's machine does not have fails there,
# not here.
self_contained() { # executable
    local needed lib bad=()
    if [ "$platform" = windows ]; then
        needed=$(objdump -p "$1" | awk '/DLL Name:/ { print $3 }')
        for lib in $needed; do
            [ -f "/c/Windows/System32/$lib" ] || bad+=("$lib")
        done
    else
        needed=$(objdump -p "$1" | awk '/NEEDED/ { print $2 }')
        for lib in $needed; do
            case $lib in
                libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | ld-linux-x86-64.so.2) ;;
                *) bad+=("$lib") ;;
            esac
        done
        echo "$1 needs glibc $(objdump -T "$1" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
    fi
    if [ ${#bad[@]} -gt 0 ]; then
        echo "error: $1 needs libraries a user's machine may not have: ${bad[*]}" >&2
        exit 1
    fi
}

build() { # program, then configure arguments
    local program=$1
    shift
    mkdir -p "$work/build-$program"
    cd "$work/build-$program"
    # Only the pinned libraries: PKG_CONFIG_PATH would be searched first, and
    # the manylinux image sets it.
    PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" "$work/ffmpeg/configure" \
        --prefix="$work/out-$program" "${common[@]}" "$@"
    require_lines config.h "#define CONFIG_${program^^} 1" \
        '#define CONFIG_SMALL 1' '#define CONFIG_RUNTIME_CPUDETECT 1' \
        '#define HAVE_X86ASM 1' '#define HAVE_AVX2_EXTERNAL 1' \
        '#define HAVE_AVX512_EXTERNAL 1'
    require DECODER "$DECODERS"
    require DEMUXER "$DEMUXERS"
    require PARSER "$PARSERS"
    require BSF "$BSFS"
    require PROTOCOL file,pipe
    if [ "$program" = ffmpeg ]; then
        require ENCODER "$ENCODERS"
        require MUXER "$MUXERS"
        require FILTER "$FILTERS"
    fi
    make -j"$jobs"
    strip "$program$exe"
    self_contained "$program$exe"
    cp "$program$exe" "$out/$program$exe"
}

build_ffmpeg() {
    build ffmpeg \
        --disable-ffprobe \
        --enable-libopus \
        --enable-libsvtav1 \
        --enable-libwebp \
        --enable-encoder="$ENCODERS" \
        --enable-muxer="$MUXERS" \
        --enable-filter="$FILTERS"
}

build_ffprobe() {
    build ffprobe \
        --disable-ffmpeg \
        --disable-avfilter \
        --disable-swscale
}

together build_ffmpeg build_ffprobe
grep -h 'needs glibc' "$work/logs/build_ffmpeg.log" "$work/logs/build_ffprobe.log" || true

echo "== NOTICE.txt"
# Everything linked into the executables whose licence asks for its notice to
# travel with the binary. GCC's own runtime is under the GCC Runtime Library
# Exception and asks for none.
notices=(
    "FFmpeg $FFMPEG_VERSION (LGPL-2.1-or-later)|$work/ffmpeg/LICENSE.md|$work/ffmpeg/COPYING.LGPLv2.1"
    "dav1d $DAV1D_VERSION|$work/dav1d/COPYING"
    "SVT-AV1 $SVTAV1_VERSION|$work/svt/LICENSE.md|$work/svt/LICENSE-BSD2.md|$work/svt/PATENTS.md"
    "Opus $OPUS_VERSION|$work/opus/COPYING"
    "libwebp $LIBWEBP_VERSION|$work/libwebp/COPYING|$work/libwebp/PATENTS"
    "zlib $ZLIB_VERSION|$zlib/LICENSE"
)
if [ "$platform" = windows ]; then
    notices+=("mingw-w64 runtime and winpthreads|/mingw64/share/licenses/crt/COPYING.MinGW-w64-runtime.txt|/mingw64/share/licenses/winpthreads/COPYING")
fi
{
    echo "These executables are FFmpeg $FFMPEG_VERSION built without --enable-gpl or"
    echo "--enable-nonfree, together with the libraries below. The FFmpeg source they"
    echo "were built from is published beside them as ffmpeg-$FFMPEG_VERSION.tar.xz."
    for entry in "${notices[@]}"; do
        IFS='|' read -ra parts <<< "$entry"
        printf '\n\n==== %s ====\n' "${parts[0]}"
        for file in "${parts[@]:1}"; do
            printf '\n'
            cat "$file"
        done
    done
} > "$out/NOTICE.txt"

echo "== source"
git -C "$work/ffmpeg" archive --format=tar --prefix="ffmpeg-$FFMPEG_VERSION/" HEAD |
    xz -6 -T0 > "$out/ffmpeg-$FFMPEG_VERSION.tar.xz"

ls -l "$out"
