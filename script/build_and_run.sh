#!/bin/sh
set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

mode=run
demo=false
for argument in "$@"; do
    case "$argument" in
        --demo) demo=true ;;
        run|--verify|--debug|--logs|--telemetry) mode=$argument ;;
        *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry] [--demo]" >&2; exit 2 ;;
    esac
done

# Respect an explicit developer directory. If only Command Line Tools are
# selected, a single installed Xcode is unambiguous and can be used locally.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
    set -- /Applications/Xcode*.app/Contents/Developer
    if [ "$#" -eq 1 ] && [ -d "$1" ]; then
        DEVELOPER_DIR=$1
        export DEVELOPER_DIR
    fi
fi

make build BUILD_CONFIGURATION=Debug BUILD_ARCHS="$(uname -m)"
app_path="$repository_root/.build/xcode/Build/Products/Debug/Rei.app"

# Ask this process to terminate normally after the new build is ready.
if pgrep -x Rei >/dev/null; then
    pkill -TERM -x Rei
    attempts=0
    while pgrep -x Rei >/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 10 ]; then
            echo "Rei has not exited; close it before relaunching." >&2
            exit 1
        fi
        sleep 1
    done
fi

set --
if [ "$demo" = true ]; then set -- --demo; fi
if [ "$mode" = --debug ]; then
    exec lldb -o 'process handle SIGTERM -s false -n false -p true' -o run -- "$app_path/Contents/MacOS/Rei" "$@"
fi
open -n "$app_path" --args "$@"
case "$mode" in
    --verify)
        sleep 2
        pgrep -x Rei >/dev/null
        echo "Rei launched successfully."
        ;;
    --logs|--telemetry)
        exec /usr/bin/log stream --info --style compact --predicate 'process == "Rei"'
        ;;
esac
