// Aurora Shaders - MetalFX bridge (aud_metalfx.m): Apple's temporal upscaler, and from macOS 26
// its denoised scaler, on the GPU the game's OpenGL context draws with. Inputs and output are
// IOSurfaces: OpenGL sees them as rectangle textures it renders into or samples, Metal as the
// textures MetalFX reads and writes. All functions run on the GL thread with the game's context
// current.
#ifndef AUD_METALFX_H
#define AUD_METALFX_H

typedef void (*AmfLogFn)(const char *fmt, ...);

// Shared images, as GL_TEXTURE_RECTANGLE textures. Inputs at render size, AMF_TEX_OUTPUT at
// output size; the guides only exist for the denoised scaler.
enum {
    AMF_TEX_COLOR,      // RGBA16F scene colour (linear, before exposure and tonemapping)
    AMF_TEX_DEPTH,      // R32F depth (hardware depth convention: 0 near, 1 far)
    AMF_TEX_MOTION,     // RG16F motion, pixels from this frame to the last (OpenGL axes)
    AMF_TEX_REACTIVE,   // R16F how much to trust this frame over the history (0 history, 1 this frame)
    AMF_TEX_OUTPUT,     // RGBA16F upscaled result
    AMF_TEX_ALBEDO,     // RGBA8 diffuse albedo (linear)
    AMF_TEX_SPECULAR,   // RGBA8 specular albedo
    AMF_TEX_NORMALS,    // RGBA16F world-space normal
    AMF_TEX_ROUGHNESS,  // R16F linear roughness
    AMF_TEX_OUTPUT_B,   // the second output when pipelined (amf_texture(AMF_TEX_OUTPUT) names the finished one)
    AMF_TEX_COUNT
};

// Metal device and queue. Returns 1 when MetalFX temporal scaling is supported here.
int amf_init(AmfLogFn log);

// 1 when the denoised scaler (MetalFX's ray reconstruction) is available too (after amf_init).
int amf_denoiser_available(void);

// "Metal 4" or "Metal": the command path in use (after amf_configure).
const char *amf_backend(void);

// (Re)creates the scaler and the shared images. denoise: the denoised scaler (reads the guide
// images too) instead of the temporal scaler. metal4: submit through Metal 4 (MTL4CommandQueue,
// MTL4FX scalers) where the system has it; the original queue measured faster on an M5 Pro
// (tools/macos_test/metalfx_test.m), so it is a choice. Returns 1 on success.
int amf_configure(int renderWidth, int renderHeight, int outputWidth, int outputHeight, int denoise, int metal4);

// GL_TEXTURE_RECTANGLE name of a shared image (0 when it does not exist).
unsigned amf_texture(int which);

// Hands this frame's inputs (already written and flushed by OpenGL) to MetalFX. jitter: the
// geometry's offset in render pixels; motionScale converts the motion image into pixels; both in
// OpenGL's axes. reset after camera cuts. Without pipelined it waits until the output is written.
// Pipelined, it returns at once and AMF_TEX_OUTPUT stays the last frame's output (written before
// amf_sync returned); the first frame after a configure waits all the same.
int amf_evaluate(float jitterX, float jitterY, float motionScaleX, float motionScaleY, int reset, int pipelined);

// Waits until MetalFX has finished the last frame handed to it, which then becomes AMF_TEX_OUTPUT.
// Call before OpenGL writes new inputs: MetalFX reads them until then. Returns 0 on a timeout.
int amf_sync(void);

// World-to-view and view-to-clip matrices (column major, OpenGL conventions) for the denoiser.
void amf_set_camera(const float *worldToView, const float *viewToClip);

// Diagnostics for hook.log: the mean time amf_evaluate waited on the GPU since the last call (ms),
// the Mac's thermal state (0 nominal, 1 fair, 2 serious, 3 critical: the system slows the GPU),
// the game's memory footprint (MB).
double amf_take_wait_ms(void);
int amf_thermal_state(void);
int amf_memory_mb(void);

// Memory the whole system decompressed per second since the last call (MB/s): high when macOS is
// short of memory and keeps compressing and restoring pages, which stalls the game and the GPU.
int amf_decompressed_mb_per_s(void);

void amf_shutdown(void);

#endif
