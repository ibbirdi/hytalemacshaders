#!/usr/bin/env bash
# Runs the MetalFX bridge on this Mac's GPU (tools/macos_test/metalfx_test.m).
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$root/build"
clang -arch arm64 -fobjc-arc -O1 -Wall -Wno-unused-parameter "$root/tools/macos_test/metalfx_test.m" "$root/hook/aud_metalfx.m" \
    -framework Foundation -framework Metal -weak_framework MetalFX -framework IOSurface -framework OpenGL \
    -o "$root/build/metalfx_test"
exec "$root/build/metalfx_test"
