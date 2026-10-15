#!/bin/bash
# Runs the ParityKit tests. With only the Command Line Tools installed, Swift Testing
# needs its framework and support library paths passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/../Packages/ParityKit"
DEV=$(xcode-select -p)
F=$DEV/Library/Developer/Frameworks
L=$DEV/Library/Developer/usr/lib
if [ -d "$F/Testing.framework" ]; then
    swift test -Xswiftc "-F$F" -Xlinker "-F$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
else
    swift test "$@"
fi
