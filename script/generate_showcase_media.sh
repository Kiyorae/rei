#!/bin/sh
set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
resources="$repository_root/Sources/ReiUI/Resources/Showcase"
ffmpeg="$repository_root/.build/media-dependencies/bundle/ffmpeg"
if [ ! -x "$ffmpeg" ]; then
    echo "Run make media-tools before generating showcase media." >&2
    exit 1
fi

workspace=$(mktemp -d "${TMPDIR:-/tmp}/rei-showcase.XXXXXX")
trap 'rm -f "$workspace/Akame.bmp"; rmdir "$workspace"' EXIT
# ImageIO handles the source PNG; the bundled media-only FFmpeg does not link zlib.
sips -s format bmp "$resources/Akame.png" --out "$workspace/Akame.bmp" >/dev/null

# A padded canvas keeps every corner of the original drawing inside the frame.
rotation='scale=320:320:force_original_aspect_ratio=decrease,pad=480:480:(ow-iw)/2:(oh-ih)/2:color=white,rotate=2*PI*t/6:fillcolor=white:ow=iw:oh=ih'
"$ffmpeg" -hide_banner -loglevel error -y -loop 1 -framerate 12 -t 6 -i "$workspace/Akame.bmp" \
    -filter_complex "$rotation,split[a][b];[a]palettegen[p];[b][p]paletteuse=dither=bayer" \
    -t 6 -loop 0 "$resources/Akame-Spin.gif"
"$ffmpeg" -hide_banner -loglevel error -y -f lavfi \
    -i 'sine=frequency=440:duration=5:sample_rate=44100' \
    -af 'volume=0.12,afade=t=in:d=0.25,afade=t=out:st=4:d=1' \
    -c:a pcm_s16le "$resources/Chime.wav"
"$ffmpeg" -hide_banner -loglevel error -y -loop 1 -framerate 24 -i "$workspace/Akame.bmp" \
    -i "$resources/Chime.wav" -vf "$rotation,format=yuv420p" -t 6 \
    -c:v h264_videotoolbox -allow_sw 1 -b:v 800k -c:a aac -movflags +faststart "$resources/Akame-Spin.mp4"
echo "Showcase GIF, audio, and video generated."
