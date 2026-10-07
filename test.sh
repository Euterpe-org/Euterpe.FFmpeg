#!/usr/bin/env bash
# Proves a build does Press's jobs before it is published:
#
#   bash test.sh [directory holding ffmpeg and ffprobe, default out]
#
# A dropped configure flag gives an FFmpeg that starts, reports a version, may
# even list the codec, and then cannot do the work, so every check here runs a
# real file through the real codec: each fixture, with the codecs, filters and
# muxers Press uses.
set -euo pipefail

dir=$(realpath "${1:-out}")
exe=
[ -f "$dir/ffmpeg.exe" ] && exe=.exe
ffmpeg=$dir/ffmpeg$exe
ffprobe=$dir/ffprobe$exe
fixtures=$(cd "$(dirname "$0")" && pwd)/fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}
run() {
    # SVT-AV1 prints its banner past -v error.
    "$ffmpeg" -hide_banner -nostdin -v error -xerror -y "$@" 2> >(grep -v '^Svt\[' >&2)
}
# One stream's fields, e.g. `field a:0 codec_name file`. A stream with side data
# (a rotation) gets an empty trailing column, and Windows adds a CR.
field() {
    "$ffprobe" -v error -select_streams "$1" -show_entries "stream=$2" -of csv=p=0 "$3" |
        tr -d '\r' | head -1 | sed 's/,*$//'
}
frames() { # file: the number of video frames it decodes to
    "$ffprobe" -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames \
        -of csv=p=0 "$1" | tr -d '\r'
}
rotation() { # file: the display matrix's rotation in degrees, 0 without one
    local r
    r=$("$ffprobe" -v error -select_streams v:0 -show_entries stream_side_data=rotation \
        -of csv=p=0 "$1" | tr -d '\r,')
    echo "${r:-0}"
}
# An animated WebP's canvas, from its VP8X chunk: 24-bit width-1 and height-1
# little-endian at offset 24. FFmpeg cannot decode animated WebP, so this and
# the frame chunks are what can be checked. BSD od ends with a blank line, where
# its offset would be.
canvas() {
    od -An -tu1 -j24 -N6 "$1" |
        awk 'NF && !done { printf "%d,%d", $1 + $2 * 256 + $3 * 65536 + 1, $4 + $5 * 256 + $6 * 65536 + 1; done = 1 }'
}
listed() { # flag name: the component appears in the listing
    "$ffmpeg" -hide_banner "$1" | awk '{ print $2 }' | tr ',' '\n' | grep -qx "$2" ||
        fail "$2 missing from $1"
}

"$ffmpeg" -hide_banner -version | head -1
"$ffprobe" -hide_banner -version | head -1
for name in libopus libsvtav1 libwebp libwebp_anim pcm_f32le pcm_s16le wrapped_avframe rawvideo; do
    listed -encoders "$name"
done
listed -decoders libdav1d
for name in ogg mp4 webp f32le null rawvideo; do listed -muxers "$name"; done
for name in aresample atrim asetpts crop scale format fps; do listed -filters "$name"; done

for source in "$fixtures"/music/*; do
    name=${source##*/}
    out=$work/$name.ogg
    run -i "$source" -map 0:a:0 -vn -c:a libopus -b:a 160k -ar 48000 -f ogg "$out"
    test "$(field a:0 codec_name,sample_rate "$out")" = "opus,48000" || fail "$name"
    # A clip cut by sample, and decoding to PCM down a pipe.
    run -i "$out" -af "atrim=start_sample=4800:end_sample=19200,asetpts=N/SR/TB" \
        -c:a libopus -ar 48000 -f ogg "$work/$name.clip.ogg"
    bytes=$(run -i "$out" -map 0:a:0 -c:a pcm_f32le -ar 44100 -ac 2 -f f32le pipe:1 | wc -c)
    test "$bytes" -gt 100000 || fail "$name decoded to $bytes bytes"
    run -i "$out" -f null -
    echo "music  $name -> opus, clip, $bytes bytes of PCM"
done

for source in "$fixtures"/cover/*; do
    name=${source##*/}
    out=$work/$name.webp
    count=$(frames "$source")
    if [ "$count" -gt 1 ]; then
        # An animated GIF stays animated, every frame cropped alike. libwebp
        # merges a frame identical to the one before into its duration, so
        # the WebP may hold fewer frames than the GIF, but never just one.
        run -i "$source" -vf "format=rgba,crop=7:5:3:1:exact=1" \
            -c:v libwebp_anim -q:v 90 -pix_fmt bgra -loop 0 -f webp "$out"
        test "$(canvas "$out")" = "7,5" || fail "$name canvas is $(canvas "$out")"
        written=$(grep -ao ANMF "$out" | wc -l)
        test "$written" -gt 1 || fail "$name lost its animation"
        echo "cover  $name -> 7x5 animated webp, $count frames in $written"
    else
        run -i "$source" -frames:v 1 -vf "format=rgba,crop=7:5:3:1:exact=1" \
            -c:v libwebp -q:v 90 -compression_level 6 -pix_fmt bgra -f webp "$out"
        test "$(field v:0 codec_name,width,height "$out")" = "webp,7,5" || fail "$name"
        run -i "$out" -f null -
        echo "cover  $name -> 7x5 webp"
    fi
done

for source in "$fixtures"/video/*; do
    name=${source##*/}
    out=$work/$name.mp4
    run -i "$source" -map 0:v:0 -an -sn -dn -ss 0.1 -t 0.5 -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
        -c:v libsvtav1 -crf 32 -preset 6 -pix_fmt yuv420p -movflags +faststart -f mp4 "$out"
    test "$(field v:0 codec_name "$out")" = av1 || fail "$name"
    # A quarter turn in the display matrix comes out as an upright picture.
    shape=$(field v:0 width,height "$source")
    case $(rotation "$source") in
        90 | -90 | 270 | -270) shape=${shape#*,},${shape%,*} ;;
    esac
    size=$(field v:0 width,height "$out")
    test "$size" = "$shape" || fail "$name came out $size, expected $shape"
    frame=$(run -i "$out" -frames:v 1 -f rawvideo -pix_fmt rgb24 pipe:1 | wc -c)
    test "$frame" -eq $((${size%,*} * ${size#*,} * 3)) || fail "$name frame is $frame bytes"
    run -i "$out" -f null -
    # A conforming H.264/H.265/AV1 source is kept by a stream copy when AV1 does
    # not come out smaller, so that path has to work as well.
    kept=
    codec=$(field v:0 codec_name "$source")
    case $codec in h264 | hevc | av1)
        copy=$work/$name.copy.mp4
        run -i "$source" -map 0:v:0 -an -sn -dn -c:v copy -movflags +faststart -f mp4 "$copy"
        test "$(field v:0 codec_name "$copy")" = "$codec" || fail "$name copy"
        run -i "$copy" -f null -
        kept=", copied as $codec"
        ;;
    esac
    echo "video  $name ($codec) -> av1 ${size/,/x}$kept"
done

echo "all checks passed"
