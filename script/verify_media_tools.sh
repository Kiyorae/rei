#!/bin/bash
set -euo pipefail

binary=${1:?Usage: verify_media_tools.sh /path/to/ffmpeg [arm64 x86_64]}
shift
if [ ! -x "$binary" ]; then echo "Missing bundled FFmpeg executable: $binary" >&2; exit 1; fi

for architecture in "$@"; do xcrun lipo "$binary" -verify_arch "$architecture"; done
dependencies=$(xcrun otool -L "$binary" | awk '/compatibility version/ {print $1}')
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *) echo "Non-system FFmpeg dependency: $dependency" >&2; exit 1 ;;
    esac
done <<< "$dependencies"

license=$("$binary" -hide_banner -L 2>&1)
if [[ "$license" != *"Lesser General Public License"* ]]; then
    echo "The bundled FFmpeg must use its LGPL configuration" >&2
    exit 1
fi
encoders=$("$binary" -hide_banner -encoders 2>/dev/null)
for encoder in pcm_s16le flac aac wmav2 vorbis libmp3lame libopencore_amrnb libspeex h264_videotoolbox; do
    if ! awk '{print $2}' <<< "$encoders" | grep -Fxq "$encoder"; then
        echo "Required FFmpeg encoder is missing: $encoder" >&2
        exit 1
    fi
done
echo "FFmpeg architecture, license, runtime dependencies, and encoder checks passed."
