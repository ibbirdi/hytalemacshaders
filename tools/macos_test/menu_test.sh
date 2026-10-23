#!/usr/bin/env bash
# Renders the in-game menu with the macOS panel into build/menu.png (tools/macos_test/menu_test.c).
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$root/build/validation"
clang -arch arm64 -fobjc-arc -O1 -c "$root/hook/aud_metalfx.m" -o "$root/build/validation/aud_metalfx.o"
cc -arch arm64 -std=gnu11 -O1 -w -DAU_SDL_PROXY=1 -DAU_HAS_DLSS=0 -DAU_HAS_METALFX=1 "$root/tools/macos_test/menu_test.c" \
    "$root/build/validation/aud_metalfx.o" -framework OpenGL -framework Foundation -framework Metal -weak_framework MetalFX \
    -framework IOSurface -framework CoreGraphics -framework CoreText -framework ImageIO -o "$root/build/menu_test"
cd "$root"
exec "$root/build/menu_test" "${1:-$root/shaderpack}" "${2:-$root/build/menu.png}"
