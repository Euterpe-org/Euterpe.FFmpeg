#!/usr/bin/env bash
# Regenerates fixtures/ with a FULL FFmpeg (lavfi, libx264, libx265,
# libmp3lame, libvorbis, libvpx, libwebp, ...), never with the build under
# test:
#
#   FFMPEG=/path/to/full/ffmpeg bash make-fixtures.sh
#
# One small file per kind of input Press accepts, with the codecs those
# files usually carry: music downloaded from music sites and apps, background
# videos downloaded from video sites or exported from editing software, and cover
# pictures. test.sh runs them all through the minimal build. Rerun only when a
# fixture must change, and commit the results.
set -euo pipefail

ffmpeg=${FFMPEG:?set FFMPEG to a full ffmpeg}
root=$(cd "$(dirname "$0")" && pwd)
out=$root/fixtures
rm -rf "$out"
mkdir -p "$out/music" "$out/cover" "$out/video"

run() {
    # SVT-AV1 prints its banner past -v error.
    "$ffmpeg" -hide_banner -nostdin -v error -y "$@" 2> >(grep -v '^Svt\[' >&2)
}

# Half a second of a 440 Hz tone at 44.1 kHz (the usual MP3 rate); mono keeps
# the uncompressed ones small.
tone=(-f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.5" -ac 1)
run "${tone[@]}" -c:a libmp3lame -b:a 64k "$out/music/mp3.mp3"
run "${tone[@]}" -c:a aac -b:a 64k "$out/music/aac.m4a"
run "${tone[@]}" -c:a alac "$out/music/alac.m4a"
run "${tone[@]}" -c:a aac -b:a 64k -f adts "$out/music/adts.aac"
run "${tone[@]}" -c:a flac "$out/music/flac.flac"
run "${tone[@]}" -c:a libopus -b:a 48k "$out/music/opus.opus"
run "${tone[@]}" -c:a libvorbis -q:a 0 "$out/music/vorbis.ogg"
run "${tone[@]}" -c:a pcm_s16le "$out/music/s16.wav"
run "${tone[@]}" -c:a pcm_s24le "$out/music/s24.wav"
run "${tone[@]}" -c:a pcm_s32le "$out/music/s32.wav"
run "${tone[@]}" -c:a pcm_f32le "$out/music/f32.wav"

# A 64x48 test picture, and five frames of it for an animated GIF.
picture=(-f lavfi -i "testsrc2=size=64x48" -frames:v 1)
run "${picture[@]}" "$out/cover/png.png"
run "${picture[@]}" -c:v mjpeg -q:v 3 -pix_fmt yuvj420p "$out/cover/jpeg.jpg"
run "${picture[@]}" -c:v libwebp -quality 60 "$out/cover/webp.webp"
run "${picture[@]}" "$out/cover/gif.gif"
run -f lavfi -i "testsrc2=size=64x48:rate=5:duration=1" -loop 0 "$out/cover/gif-animated.gif"

# One second at 10 fps, 128x72 (SVT-AV1 wants at least 64 lines), with the
# audio track each container usually carries; Press drops it.
clip=(-f lavfi -i "testsrc2=size=128x72:rate=10:duration=1"
    -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=1" -shortest)
run "${clip[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 32k "$out/video/h264-aac.mp4"
run "${clip[@]}" -c:v libx264 -pix_fmt yuv420p -an "$out/video/h264.m4v"
run "${clip[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 32k "$out/video/h264-aac.mov"
run "${clip[@]}" -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p -tag:v hvc1 \
    -c:a aac -b:a 32k "$out/video/hevc-aac.mp4"
run "${clip[@]}" -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p -an "$out/video/hevc.mkv"
run "${clip[@]}" -c:v libsvtav1 -crf 40 -pix_fmt yuv420p -an "$out/video/av1.mp4"
run "${clip[@]}" -c:v libsvtav1 -crf 40 -pix_fmt yuv420p -c:a libopus -b:a 32k "$out/video/av1-opus.webm"
run "${clip[@]}" -c:v libvpx-vp9 -b:v 100k -c:a libopus -b:a 32k "$out/video/vp9-opus.webm"
run "${clip[@]}" -c:v libvpx -b:v 100k -c:a libvorbis -q:a 0 "$out/video/vp8-vorbis.webm"
run "${clip[@]}" -c:v mpeg4 -q:v 8 -c:a libmp3lame -b:a 32k "$out/video/mpeg4-mp3.avi"
run "${clip[@]}" -c:v prores_ks -profile:v 0 -c:a pcm_s16le "$out/video/prores-pcm.mov"

# Two MP4 shapes that trip naive readers: a picture stored one way round with a
# display matrix that turns it a quarter turn (what phones write), and a
# fragmented file whose samples live in moof/trun behind an empty stts.
plain=(-f lavfi -i "testsrc2=size=320x180:rate=30:duration=1"
    -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -an)
run "${plain[@]}" "$out/video/plain.tmp.mp4"
run -display_rotation 90 -i "$out/video/plain.tmp.mp4" -c copy "$out/video/h264-rotated.mp4"
rm "$out/video/plain.tmp.mp4"
run "${plain[@]}" -movflags frag_keyframe+empty_moov+default_base_moof "$out/video/h264-fragmented.mp4"

du -ab "$out" | sort -k2
