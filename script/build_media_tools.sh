#!/bin/bash
set -euo pipefail

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cache="$repository_root/.build/media-dependencies"
downloads="$cache/downloads"
sources="$cache/sources"
lock="$repository_root/script/media-dependencies.lock"
architectures=${BUILD_ARCHS:-"arm64 x86_64"}
deployment_target=${MACOSX_DEPLOYMENT_TARGET:-26.0}
jobs=${MEDIA_BUILD_JOBS:-4}
sdk=$(xcrun --sdk macosx --show-sdk-path)
compiler=$(xcrun --find clang)
cxx_compiler=$(xcrun --find clang++)
mkdir -p "$downloads" "$sources" "$cache/builds"

for architecture in $architectures; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported media architecture: $architecture" >&2; exit 1 ;; esac
done
if [ -z "$architectures" ]; then echo "BUILD_ARCHS cannot be empty" >&2; exit 1; fi

fingerprint=$(
    {
        cat "$lock" "$0"
        xcodebuild -version
        printf '%s\n' "$sdk" "$deployment_target" "$architectures"
    } | shasum -a 256 | awk '{print $1}'
)
build="$cache/builds/$fingerprint"

if [ ! -f "$build/complete" ]; then
    while IFS='|' read -r name version archive checksum source_url; do
        case "$name" in ''|\#*) continue ;; esac
        destination="$downloads/$archive"
        if [ ! -f "$destination" ]; then
            partial=$(mktemp "$downloads/.download.XXXXXX")
            echo "Downloading $name $version from its upstream release site"
            if ! curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
                --max-time 300 "$source_url" --output "$partial"; then
                rm -f "$partial"
                exit 1
            fi
            actual=$(shasum -a 256 "$partial" | awk '{print $1}')
            if [ "$actual" != "$checksum" ]; then
                rm -f "$partial"
                echo "Source checksum mismatch for $archive" >&2
                exit 1
            fi
            mv "$partial" "$destination"
        fi
        actual=$(shasum -a 256 "$destination" | awk '{print $1}')
        if [ "$actual" != "$checksum" ]; then
            echo "Cached source checksum mismatch: $destination" >&2
            exit 1
        fi
        if [ ! -d "$sources/$name-$version" ]; then
            tar -xf "$destination" -C "$sources"
        fi
    done < "$lock"

    mkdir -p "$build/host" "$build/host-prefix" "$build/bundle/MediaTools/Sources" "$build/bundle/MediaTools/Licenses"
    # pkgconf is a build tool only. Building it here avoids depending on Homebrew.
    if [ ! -x "$build/host-prefix/bin/pkgconf" ]; then
        echo "Building isolated pkgconf"
        (
            cd "$build/host"
            trap 'tail -n 50 ./*.log >&2' ERR
            CC="$compiler" CFLAGS="-O2 -std=gnu11 -isysroot $sdk" \
                "$sources/pkgconf-3.0.5/configure" --prefix="$build/host-prefix" \
                --disable-shared --enable-static --with-pkg-config-dir= \
                > configure.log 2>&1
            make -j "$jobs" > build.log 2>&1
            make install > install.log 2>&1
        )
    fi
    pkgconf="$build/host-prefix/bin/pkgconf"

    for architecture in $architectures; do
        prefix="$build/$architecture/prefix"
        mkdir -p "$prefix"
        flags="-O2 -arch $architecture -isysroot $sdk -mmacosx-version-min=$deployment_target"
        case "$architecture" in arm64) host=aarch64-apple-darwin ;; x86_64) host=x86_64-apple-darwin ;; esac
        for package in lame-4.0 opencore-amr-0.1.6 speex-1.2.1; do
            package_build="$build/$architecture/$package"
            if [ -f "$package_build/complete" ]; then continue; fi
            mkdir -p "$package_build"
            echo "Building $package for $architecture"
            options=()
            case "$package" in
                lame-*) options+=(--disable-frontend --disable-decoder --disable-mp3x --disable-mp3rtp --disable-nasm) ;;
                opencore-amr-*) options+=(--disable-examples) ;;
                speex-*) options+=(--disable-binaries --disable-examples) ;;
            esac
            (
                cd "$package_build"
                trap 'tail -n 50 ./*.log >&2' ERR
                CC="$compiler" CXX="$cxx_compiler" CFLAGS="$flags -std=gnu11" CXXFLAGS="$flags" \
                    LDFLAGS="$flags" PKG_CONFIG="$pkgconf" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
                    "$sources/$package/configure" --prefix="$prefix" --host="$host" \
                    --disable-shared --enable-static --disable-dependency-tracking "${options[@]}" \
                    > configure.log 2>&1
                make -j "$jobs" > build.log 2>&1
                make install > install.log 2>&1
                touch complete
            )
        done

        ffmpeg_build="$build/$architecture/ffmpeg"
        mkdir -p "$ffmpeg_build"
        if [ ! -f "$ffmpeg_build/complete" ]; then
            echo "Building FFmpeg 9.0.1 for $architecture"
            (
                cd "$ffmpeg_build"
                trap 'tail -n 50 ./*.log >&2' ERR
                PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
                    "$sources/ffmpeg-9.0.1/configure" \
                    --prefix="$prefix" --target-os=darwin --arch="$architecture" --enable-cross-compile \
                    --cc="$compiler" --cxx="$cxx_compiler" --sysroot="$sdk" \
                    --extra-cflags="$flags -I$prefix/include" --extra-ldflags="$flags -L$prefix/lib" \
                    --pkg-config="$pkgconf" --pkg-config-flags=--static \
                    --disable-autodetect --disable-shared --enable-static --disable-doc --disable-debug \
                    --disable-ffplay --disable-ffprobe --disable-network --disable-x86asm \
                    --disable-indevs --disable-outdevs --enable-indev=lavfi \
                    --enable-videotoolbox --enable-audiotoolbox --enable-version3 \
                    --enable-libmp3lame --enable-libopencore-amrnb --enable-libspeex \
                    > configure.log 2>&1
                make -j "$jobs" ffmpeg > build.log 2>&1
                touch complete
            )
        fi
    done

    binaries=()
    for architecture in $architectures; do binaries+=("$build/$architecture/ffmpeg/ffmpeg"); done
    xcrun lipo -create "${binaries[@]}" -output "$build/bundle/ffmpeg"
    /usr/bin/codesign --force --sign - "$build/bundle/ffmpeg"

    while IFS='|' read -r name version archive checksum source_url; do
        case "$name" in ''|\#*) continue ;; esac
        cp "$downloads/$archive" "$build/bundle/MediaTools/Sources/$archive"
        for license in "$sources/$name-$version"/COPYING* "$sources/$name-$version"/LICENSE*; do
            [ -f "$license" ] || continue
            cp "$license" "$build/bundle/MediaTools/Licenses/$name-$(basename "$license")"
        done
    done < "$lock"
    cp "$lock" "$0" "$repository_root/script/verify_media_tools.sh" "$build/bundle/MediaTools/"
    for architecture in $architectures; do
        cp "$build/$architecture/ffmpeg/config.h" "$build/bundle/MediaTools/config-$architecture.h"
        cp "$build/$architecture/ffmpeg/ffbuild/config.log" "$build/bundle/MediaTools/config-$architecture.log"
    done
    cat > "$build/bundle/MediaTools/NOTICE.txt" <<'NOTICE'
Rei includes an independently executable FFmpeg helper, built from unmodified upstream sources.
FFmpeg: https://ffmpeg.org/ - LGPL 3.0 or later (version3 enabled; GPL/nonfree disabled).
LAME: https://lame.sourceforge.io/ - LGPL 2.0 or later.
OpenCORE AMR: https://opencore-amr.sourceforge.net/ - Apache License 2.0.
Speex: https://speex.org/ - BSD 3-Clause.
pkgconf: https://github.com/pkgconf/pkgconf - ISC (build tool only).

Exact source archives, copyright/license notices, configuration logs, source checksums,
and the build script are included in this directory. No Homebrew libraries are required.
Rebuild within the Rei source checkout by placing these scripts in script/ and running:
BUILD_ARCHS="arm64 x86_64" ./script/build_media_tools.sh
The executable can be replaced with a compatible FFmpeg build at Contents/MacOS/ffmpeg;
re-sign a locally modified app bundle as needed for macOS to launch it.
NOTICE
    "$repository_root/script/verify_media_tools.sh" "$build/bundle/ffmpeg" $architectures
    touch "$build/complete"
fi

mkdir -p "$cache/bundle"
ditto "$build/bundle" "$cache/bundle"
echo "Bundled media tools ready: $cache/bundle/ffmpeg"
