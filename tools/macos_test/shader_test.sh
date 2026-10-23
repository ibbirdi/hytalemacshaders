#!/usr/bin/env bash
# Compiles the pack's shader variants with Apple's GLSL compiler (headless OpenGL 4.1 core
# context), the way the macOS hook hands them to the driver. Needs a prepared pack (original/).
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
pack=${1:-"$root/shaderpack"}
mkdir -p "$root/build/validation"
cc -arch arm64 -std=gnu11 -O1 -w -DAU_SDL_PROXY=1 -DAU_HAS_DLSS=0 $(pkg-config --cflags cairo) -I"$(pkg-config --variable=includedir cairo)" \
    "$root/tools/shader_test/test.c" -framework OpenGL -L"$(pkg-config --variable=libdir cairo)" -lcairo \
    -o "$root/build/shader_test"
cd "$root"
exec "$root/build/shader_test" "$pack"
