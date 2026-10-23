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

// Hands this frame's inputs (already written and flushed by OpenGL) to MetalFX and waits until
// the output is written. jitter: the geometry's offset in render pixels; motionScale converts the
// motion image into pixels; both in OpenGL's axes. reset after camera cuts.
int amf_evaluate(float jitterX, float jitterY, float motionScaleX, float motionScaleY, int reset);

// World-to-view and view-to-clip matrices (column major, OpenGL conventions) for the denoiser.
void amf_set_camera(const float *worldToView, const float *viewToClip);

void amf_shutdown(void);

#endif
