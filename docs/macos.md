# macOS port

## What runs

On macOS the official launcher installs a native arm64 client that renders through SDL3 and
OpenGL 4.1, like the Linux one. Aurora therefore uses the Linux hook: `build.sh`
builds it as `libaurora-sdl.dylib`, an SDL3 proxy that re-exports the game's own library, linked
against a placeholder named `@loader_path/libSDL3.aurora-original.dylib`. The installer puts the
proxy in place of `Hytale.app/Contents/MacOS/libSDL3.dylib` and renames the original next to it.
Hytale looks up SDL functions with `dlsym`, so the hooked ones come from the proxy and the rest
from the original library. The pack lives in `Client/.aurora/shaderpack`, outside the app bundle,
so saving a setting never touches signed files.

The installer is the Linux one (`tools/linux_install.py`, `tools/linux_hook.py`) with macOS
branches: paths inside the bundle, a Mach-O header check, `pgrep` instead of `/proc`, and the
signing steps below. `install.sh` creates `build/venv` with Pillow, because the system's Python
refuses system-wide `pip` installs. `setup-macos.sh` wraps all of it in one command. The installer
follows the patchline the launcher plays (`patchline.json`) and picks the starting settings from
the chip (`mac_tier`: M4 Pro and later high, M1-M3 Pro / Max and M3 / M4 medium, M1 / M2 low).

## Signing

Hypixel signs `Hytale.app` with the hardened runtime, whose library validation rejects libraries
from any other team. A test binary with the hardened runtime refuses an ad-hoc signed library
("different Team IDs") and loads it once re-signed without it. The installer therefore runs
`codesign --force --sign - --preserve-metadata=identifier,entitlements` on the bundle. That keeps
the identifier and entitlements (microphone, network) and replaces Hypixel's signature with an
ad-hoc one that has no hardened runtime.

Before the first re-sign, the installer checks Hypixel's signature with
`codesign --verify --strict` and saves the signed executable and `_CodeSignature/CodeResources`
in `Client/.aurora/signature`. Uninstalling puts them back only while the executable is still the
one Aurora signed, so an older executable is never copied over an update. If an update replaced
the executable under the hook, `./install.sh` undoes the old install first and saves the new
signature. `tools/macos_test/test_install.py` covers install, reinstall, uninstall, an update of
the executable alone and an update of the whole bundle. The same round trip on a copy of the real
0.7.3 client left the bundle byte-for-byte identical, with Hypixel's signature valid again.

## What stays off

`GL_ARB_shader_image_load_store` is not among the 43 extensions of macOS's OpenGL 4.1. The light
list behind **Colored area lights** and **Coloured light fog** is a lock-free hash table built on
image atomics, and the Original GI denoiser keeps its history in images: those stay off (the hook
appends `#define`s after `AU_Settings.glsl`, and the macOS menu hides their options). DLSS is
NVIDIA-only; MetalFX takes its place.

## Voxel grid without image load/store

Path tracing and the voxel **Scattering method** read a 256x128x256 block grid. On macOS
(`AU_VOXEL_ATLAS`) it lives in two 2D textures, z slices in a 16x16 tile atlas (4096x2048, R32UI
cells and RGBA8 colours), which the shaders read with `texelFetch`. DeferredFS's pass 1 runs at a
quarter of the size, on another pixel of each 4x4 block every frame, and writes what each terrain
pixel shows (`AU_VoxFeedAtlas`): the block behind the surface, a block in front of a face whose
centre is clearly empty (broken blocks go), the surface's colour. The hook scatters one point per
feed texel into the atlas (`vox_atlas_feed`). Only terrain pixels count (the G-buffer bit
MapChunkFS sets), so mobs leave no trails.

## MetalFX

`hook/aud_metalfx.m` replaces DLSS. PostEffectFS draws a second time into IOSurfaces (colour
before exposure, depth, motion, a reactive mask; with the **Denoised scaler** also albedo,
specular, normals and roughness), which OpenGL sees as rectangle textures and Metal as textures.
After `glFlush` MetalFX upscales them; OpenGL cannot wait for Metal on the GPU, so the hook waits
on a shared event, then PostEffectFS's resolve mode tonemaps the result onto the window.
**Render resolution** uses the SDL pixel-size hook, so the UI keeps full resolution.

`tools/macos_test/metalfx_test.sh` runs the bridge on the GPU. A jittered sharp edge converges
only with the right jitter and motion signs; on an M5 Pro the right ones give 1.2 px wide edges
and the wrong ones 3-4 px. It also times the scalers at 2755x1686 -> 4112x2516: 3.9 ms for the
temporal scaler (4.3 ms through Metal 4), 22 ms for the denoised one (14 ms from 50 percent).

In game the original queue is the slower one: about 20 seconds after the game comes to the front,
macOS lowers the GPU clock step by step to its lowest state while the GPU stays busy (P13 to P1,
16 W to 2 W on an M5 Pro, 40 fps to 20), and it climbs back as soon as MetalFX is off or the game
goes to the background. Through Metal 4 the clock held longer (55-60 fps at 67 percent) but
fell all the same after a few minutes. What sets it off is the wait: the CPU blocked until
MetalFX finished every frame, so the GPU idled while the CPU caught up, and macOS read the frames
as limited by the CPU. With MetalFX off the clock stayed at its top state for minutes.
**Pipelined** (on by default) hands each frame to MetalFX without waiting and shows the output of
the frame before, which is finished by then: the 3D image is one frame later (about 17 ms at 60
fps), the UI is not. **Submit through Metal 4** is on by default too; systems before macOS 26 use
the original queue. The installer turns it on once for earlier installations (`AU_MAC_SETTINGS`).

`tools/macos_test/metalfx_test.sh` gives unsteady edge widths while the game uses the GPU at the
same time; run it with the game closed.

## Performance on Apple Silicon

New installations (and the built-in profiles on macOS) start with MetalFX at 67 percent,
**Sub-pixel jitter** for the TAA, **Half-resolution GI and light shafts**, and capped per-pixel
sample counts (GI rays 4, light shafts 16, shadow samples 16, distant shadow steps 24).

## Apple's OpenGL

Two differences broke shaders that compile and draw on other platforms.

Apple's compiler rejects an `#extension` directive that follows any code. The pack inserts
declarations above the game's own directives (`uHookTextureLodBias` in MapChunkFS and
BlockyModelFS, the tonemap include in ParticleFS), so those three failed to compile and fell back
to the game's shaders. On macOS the hook now moves every `#extension` line to the top of an
override. All of them are `: enable`, so lifting them out of `#if` blocks is safe; an unsupported
one only produces a warning.

The macOS client also binds its own textures to units 16-18 (`game uses texture unit 16` and
`18` in `hook.log`), where the hook kept the block materials, emission map and SSS masks. In the
water shader the hook's material atlas and a texture of the game's both ended up on unit 18, and
the water vanished while the riverbed under it still rendered. Taking the atlas off that unit
brought the water back. OpenGL forbids samplers of different types on one unit, and Apple's
driver skips such draws. On macOS the hook's three units now start at 32, within the 80 combined
units macOS allows; other platforms keep 16-18.

## Shared fix

The SDL path never advanced `g_frame`; only `wglSwapBuffers` did. On Linux as well, temporal
reprojection (`temporal_prepare`) therefore kept the first frame's camera, and `uHookFrame` stayed
at 0. `SDL_GL_SwapWindow` now advances the counter.

## Other differences

- Shader hot reload polls `programs/` and `include/` twice a second on a background thread
  instead of using inotify; a menu save reloads once.
- The menu draws with CoreGraphics and CoreText (`hook/mac_panel.h`) in place of cairo, so only
  Apple's command line tools are needed. `tools/macos_test/menu_test.sh` renders it into a PNG.
- Mac keyboards have no Home or Pause key. **fn+Left** sends Home and opens the menu, and
  **General → Shaders** does what Pause does elsewhere. Mouse editing uses Ctrl, as on Linux.

## Performance

On a MacBook Pro with an M4 Pro (macOS 27.2, Hytale 0.7.3, game window at 4112×2516), the default
profile ran at 37-48 fps in a river scene where vanilla ran at 79 fps.

## Tested

- In game on that machine: every override compiles and links (`hook.log` has no `COMPILE ERROR`,
  `LINK ERROR` or `REJECTED` lines); water, sky, clouds, shadows and the menu render; settings
  reload while playing.
- `tools/macos_test/test_install.py`, and `tools/linux_test` run on macOS with `sys.platform` set
  to `linux`.
- `tools/macos_test/shader_test.sh`: every shader variant compiled by Apple's GLSL compiler in a
  headless OpenGL 4.1 context, plus the hook's half-resolution draw, its MetalFX present and the
  voxel atlas scatter run on the driver.
- `tools/macos_test/metalfx_test.sh`: the MetalFX bridge on the GPU (see MetalFX).
- The Linux branches of the hook pass a syntax check against stub Linux headers. They have not
  been built or run on Linux.

## Not tested

- MetalFX, half-resolution effects and the voxel atlas in the game itself: the tests run the
  hook's code on the driver, not inside Hytale.

- Intel Macs (the installer accepts arm64 only), other macOS versions and other Hytale versions.
- How the launcher's updates and repairs treat the re-signed bundle over time.
- Whether macOS asks for App Management permission when the installer runs from Terminal.
