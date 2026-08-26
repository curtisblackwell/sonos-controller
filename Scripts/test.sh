#!/bin/bash
set -euo pipefail

# `swift test` on a machine with only the Command Line Tools installed can't find the
# bundled swift-testing framework - it ships under Library/Developer rather than in the
# default search paths, so both the compile and the dlopen at launch fail. Point the
# compiler, linker, and runtime at it explicitly. With full Xcode selected these paths
# don't exist and plain `swift test` works, so we only add them when they're present.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
LIBS="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"

EXTRA_ARGS=()
if [ -d "$FRAMEWORKS" ]; then
    EXTRA_ARGS+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
if [ -d "$LIBS" ]; then
    EXTRA_ARGS+=(-Xlinker -rpath -Xlinker "$LIBS")
fi

# macOS ships bash 3.2, where expanding an empty array under `set -u` is an unbound
# variable error - which would break the very case this script is meant to fall through:
# full Xcode selected, no extra args needed.
exec swift test "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" "$@"
