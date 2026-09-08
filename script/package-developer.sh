#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <app-path> <output-directory>" >&2
    exit 64
fi
app_path=$1
output_directory=$2
repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
info_plist="$app_path/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")
build_number=$(plutil -extract CFBundleVersion raw -o - "$info_plist")
executable=$(plutil -extract CFBundleExecutable raw -o - "$info_plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid application version or build number." >&2
    exit 65
fi
for architecture in arm64 x86_64; do
    xcrun lipo "$app_path/Contents/MacOS/$executable" -verify_arch "$architecture"
done
"$repository_root/script/verify_media_tools.sh" "$app_path/Contents/MacOS/ffmpeg" arm64 x86_64

artifact="Rei-v${version}-${build_number}-developer.zip"
mkdir -p "$output_directory"
for name in "$artifact" SHA256SUMS; do
    if [[ -e "$output_directory/$name" ]]; then
        echo "Refusing to overwrite developer artifact: $output_directory/$name" >&2
        exit 73
    fi
done
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/rei-developer.XXXXXX")
cleanup() { rm -rf -- "$staging_root"; }
trap cleanup EXIT

# Sign a copy so packaging never changes the build product or its release identity.
ditto "$app_path" "$staging_root/Rei.app"
codesign --force --sign - --timestamp=none "$staging_root/Rei.app/Contents/MacOS/ffmpeg"
codesign --force --sign - --timestamp=none "$staging_root/Rei.app"
codesign --verify --deep --strict "$staging_root/Rei.app"
ditto -c -k --sequesterRsrc --keepParent "$staging_root/Rei.app" "$output_directory/$artifact"
(cd "$output_directory" && shasum -a 256 "$artifact" > SHA256SUMS)
printf 'Developer app: %s/%s\n' "$output_directory" "$artifact"
