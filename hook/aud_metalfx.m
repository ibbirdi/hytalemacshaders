// Aurora Shaders - MetalFX bridge for the macOS hook (aud_metalfx.h).
//
// OpenGL renders the inputs into IOSurface-backed rectangle textures and flushes; Metal reads the
// same IOSurfaces. Metal 4 (MTL4CommandQueue, MTL4FX scalers, a residency set for the shared
// images) where the system offers it, the original Metal command queue otherwise. macOS has no
// way to make an OpenGL context wait for Metal on the GPU, so the bridge waits on the CPU (a shared
// event) before OpenGL samples the output.
//
// IOSurface rows are in memory order: Metal's top row is OpenGL's bottom one, so MetalFX sees the
// frame upside down, consistently for every input and the output. The jitter and the motion
// vectors keep OpenGL's signs all the same: tools/macos_test/metalfx_test.m measures which
// convention gives sharp edges on this hardware, and flipping the vertical ones blurs them.
#define GL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <mach/mach.h>
#include <time.h>
#include "aud_metalfx.h"

static AmfLogFn amf_log;
static int g_initialised, g_supported, g_denoiserSupported;
static id<MTLDevice> g_device;
static id<MTLSharedEvent> g_event;
static uint64_t g_eventValue;
static id<MTLCommandQueue> g_queue;     // Metal
static id g_queue4, g_allocator4, g_commandBuffer4, g_compiler4, g_residency;   // Metal 4
static id g_scaler;
static int g_metal4, g_denoise, g_renderWidth, g_renderHeight, g_framesSinceConfigure;
static IOSurfaceRef g_surfaces[AMF_TEX_COUNT];
static id<MTLTexture> g_textures[AMF_TEX_COUNT];
static GLuint g_gl[AMF_TEX_COUNT];
static simd_float4x4 g_worldToView, g_viewToClip;
static double g_waitTotal;
static int g_waitCount;
// Pipelined: the scaler writes one output while OpenGL samples the other, finished one.
static int g_shownOutput = AMF_TEX_OUTPUT, g_pendingOutput = -1;
static uint64_t g_pendingValue;

static const struct {
    MTLPixelFormat metal;
    GLenum internal, format, type;
    uint32_t fourcc;
    int bytes;
} g_formats[AMF_TEX_COUNT] = {
    [AMF_TEX_COLOR] = {MTLPixelFormatRGBA16Float, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, 'RGhA', 8},
    [AMF_TEX_DEPTH] = {MTLPixelFormatR32Float, GL_R32F, GL_RED, GL_FLOAT, 'L00f', 4},
    [AMF_TEX_MOTION] = {MTLPixelFormatRG16Float, GL_RG, GL_RG, GL_HALF_FLOAT, '2C0h', 4},   // CGL refuses GL_RG16F here
    [AMF_TEX_REACTIVE] = {MTLPixelFormatR16Float, GL_R16F, GL_RED, GL_HALF_FLOAT, 'L00h', 2},
    [AMF_TEX_OUTPUT] = {MTLPixelFormatRGBA16Float, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, 'RGhA', 8},
    [AMF_TEX_ALBEDO] = {MTLPixelFormatBGRA8Unorm, GL_RGBA8, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, 'BGRA', 4},   // and RGBA byte order
    [AMF_TEX_SPECULAR] = {MTLPixelFormatBGRA8Unorm, GL_RGBA8, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, 'BGRA', 4},
    [AMF_TEX_NORMALS] = {MTLPixelFormatRGBA16Float, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, 'RGhA', 8},
    [AMF_TEX_ROUGHNESS] = {MTLPixelFormatR16Float, GL_R16F, GL_RED, GL_HALF_FLOAT, 'L00h', 2},
    [AMF_TEX_OUTPUT_B] = {MTLPixelFormatRGBA16Float, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, 'RGhA', 8},
};

// The game runs from macOS 12; MetalFX exists from 13 (the framework is weak-linked).
static int amf_setup(void) API_AVAILABLE(macos(13.0));

int amf_init(AmfLogFn log)
{
    amf_log = log;
    if (g_initialised) return g_supported;
    g_initialised = 1;
    if (@available(macOS 13.0, *)) return amf_setup();
    amf_log("metalfx: MetalFX needs macOS 13 or later");
    return 0;
}

static int amf_setup(void)
{
    @autoreleasepool {
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device || ![MTLFXTemporalScalerDescriptor supportsDevice:g_device]) {
            amf_log("metalfx: this GPU has no MetalFX temporal scaling");
            return 0;
        }
        g_event = [g_device newSharedEvent];
        if (@available(macOS 26.0, *)) {
            g_denoiserSupported = [MTLFXTemporalDenoisedScalerDescriptor supportsDevice:g_device];
            if ([MTLFXTemporalScalerDescriptor supportsMetal4FX:g_device]) {
                NSError *error = nil;
                g_queue4 = [g_device newMTL4CommandQueue];
                g_allocator4 = [g_device newCommandAllocator];
                g_commandBuffer4 = [g_device newCommandBuffer];
                g_compiler4 = [g_device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
                if (!g_queue4 || !g_allocator4 || !g_commandBuffer4 || !g_compiler4) {
                    amf_log("metalfx: Metal 4 setup failed (%s), using Metal", error ? error.localizedDescription.UTF8String : "no detail");
                    g_queue4 = g_allocator4 = g_commandBuffer4 = g_compiler4 = nil;
                }
            }
        }
        g_queue = [g_device newCommandQueue];
        g_supported = g_event && g_queue;
        amf_log("metalfx: %s, %s available, denoised scaler %s", g_device.name.UTF8String,
                g_queue4 ? "Metal 4" : "Metal", g_denoiserSupported ? "available" : "unavailable");
    }
    return g_supported;
}

int amf_denoiser_available(void)
{
    return g_denoiserSupported;
}

const char *amf_backend(void)
{
    return g_metal4 ? "Metal 4" : "Metal";
}

unsigned amf_texture(int which)
{
    if (which == AMF_TEX_OUTPUT) which = g_shownOutput;
    return which >= 0 && which < AMF_TEX_COUNT ? g_gl[which] : 0;
}

static int amf_wait(uint64_t value, uint64_t timeout)
{
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL signalled = [g_event waitUntilSignaledValue:value timeoutMS:timeout];
    g_waitTotal += (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6;
    g_waitCount++;
    if (!signalled) amf_log("metalfx: the GPU did not finish within %llu ms", (unsigned long long)timeout);
    return signalled;
}

int amf_sync(void)
{
    if (g_pendingOutput < 0) return 1;
    int output = g_pendingOutput;
    g_pendingOutput = -1;
    if (!amf_wait(g_pendingValue, 2000)) return 0;
    g_shownOutput = output;
    return 1;
}

static void amf_release(void)
{
    if (g_pendingOutput >= 0) [g_event waitUntilSignaledValue:g_pendingValue timeoutMS:2000];
    g_pendingOutput = -1;
    g_shownOutput = AMF_TEX_OUTPUT;
    if (g_residency && g_queue4) {
        if (@available(macOS 26.0, *)) [(id<MTL4CommandQueue>)g_queue4 removeResidencySet:g_residency];
    }
    g_residency = nil;
    g_scaler = nil;
    GLint previous = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &previous);
    for (int which = 0; which < AMF_TEX_COUNT; which++) {
        if (g_gl[which]) {
            if ((GLuint)previous == g_gl[which]) previous = 0;
            glDeleteTextures(1, &g_gl[which]);
        }
        g_gl[which] = 0;
        g_textures[which] = nil;
        if (g_surfaces[which]) CFRelease(g_surfaces[which]);
        g_surfaces[which] = NULL;
    }
    glBindTexture(GL_TEXTURE_RECTANGLE, (GLuint)previous);
}

// One shared image: the IOSurface, Metal's view of it with the usage MetalFX asks for, and
// OpenGL's rectangle texture on it.
static int amf_image(int which, int width, int height, MTLTextureUsage usage)
{
    size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * g_formats[which].bytes);
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(width), (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @(g_formats[which].bytes), (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (id)kIOSurfacePixelFormat: @(g_formats[which].fourcc),
    };
    g_surfaces[which] = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!g_surfaces[which]) return 0;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:g_formats[which].metal
                                                                                          width:width height:height mipmapped:NO];
    descriptor.usage = usage | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    g_textures[which] = [g_device newTextureWithDescriptor:descriptor iosurface:g_surfaces[which] plane:0];
    if (!g_textures[which]) return 0;
    glGenTextures(1, &g_gl[which]);
    glBindTexture(GL_TEXTURE_RECTANGLE, g_gl[which]);
    CGLError error = CGLTexImageIOSurface2D(CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE, g_formats[which].internal, width, height,
                                            g_formats[which].format, g_formats[which].type, g_surfaces[which], 0);
    GLenum filter = which == AMF_TEX_OUTPUT || which == AMF_TEX_OUTPUT_B ? GL_LINEAR : GL_NEAREST;
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, filter);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (error != kCGLNoError) {
        amf_log("metalfx: OpenGL cannot use the shared image %d (CGL error %d)", which, (int)error);
        return 0;
    }
    return 1;
}

static int amf_create(int renderWidth, int renderHeight, int outputWidth, int outputHeight, int denoise, int metal4) API_AVAILABLE(macos(13.0));

int amf_configure(int renderWidth, int renderHeight, int outputWidth, int outputHeight, int denoise, int metal4)
{
    if (!g_supported) return 0;
    if (@available(macOS 13.0, *)) return amf_create(renderWidth, renderHeight, outputWidth, outputHeight, denoise, metal4);
    return 0;
}

static int amf_create(int renderWidth, int renderHeight, int outputWidth, int outputHeight, int denoise, int metal4)
{
    @autoreleasepool {
        amf_release();
        GLint previous = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &previous);
        denoise = denoise && g_denoiserSupported;
        g_metal4 = 0;
        MTLTextureUsage usage[AMF_TEX_COUNT] = {0};
        if (denoise) {
            if (@available(macOS 26.0, *)) {
                MTLFXTemporalDenoisedScalerDescriptor *descriptor = [MTLFXTemporalDenoisedScalerDescriptor new];
                descriptor.colorTextureFormat = g_formats[AMF_TEX_COLOR].metal;
                descriptor.depthTextureFormat = g_formats[AMF_TEX_DEPTH].metal;
                descriptor.motionTextureFormat = g_formats[AMF_TEX_MOTION].metal;
                descriptor.diffuseAlbedoTextureFormat = g_formats[AMF_TEX_ALBEDO].metal;
                descriptor.specularAlbedoTextureFormat = g_formats[AMF_TEX_SPECULAR].metal;
                descriptor.normalTextureFormat = g_formats[AMF_TEX_NORMALS].metal;
                descriptor.roughnessTextureFormat = g_formats[AMF_TEX_ROUGHNESS].metal;
                descriptor.outputTextureFormat = g_formats[AMF_TEX_OUTPUT].metal;
                descriptor.inputWidth = renderWidth;
                descriptor.inputHeight = renderHeight;
                descriptor.outputWidth = outputWidth;
                descriptor.outputHeight = outputHeight;
                descriptor.autoExposureEnabled = YES;
                descriptor.requiresSynchronousInitialization = YES;
                descriptor.reactiveMaskTextureEnabled = YES;
                descriptor.reactiveMaskTextureFormat = g_formats[AMF_TEX_REACTIVE].metal;
                if (metal4 && g_queue4 && [MTLFXTemporalDenoisedScalerDescriptor supportsMetal4FX:g_device]) {
                    g_scaler = [descriptor newTemporalDenoisedScalerWithDevice:g_device compiler:g_compiler4];
                    g_metal4 = g_scaler != nil;
                }
                if (!g_scaler) g_scaler = [descriptor newTemporalDenoisedScalerWithDevice:g_device];
                id<MTLFXTemporalDenoisedScalerBase> scaler = g_scaler;
                if (scaler) {
                    usage[AMF_TEX_COLOR] = scaler.colorTextureUsage;
                    usage[AMF_TEX_DEPTH] = scaler.depthTextureUsage;
                    usage[AMF_TEX_MOTION] = scaler.motionTextureUsage;
                    usage[AMF_TEX_REACTIVE] = MTLTextureUsageShaderRead;
                    usage[AMF_TEX_OUTPUT] = scaler.outputTextureUsage;
                    usage[AMF_TEX_ALBEDO] = scaler.diffuseAlbedoTextureUsage;
                    usage[AMF_TEX_SPECULAR] = scaler.specularAlbedoTextureUsage;
                    usage[AMF_TEX_NORMALS] = scaler.normalTextureUsage;
                    usage[AMF_TEX_ROUGHNESS] = scaler.roughnessTextureUsage;
                    usage[AMF_TEX_OUTPUT_B] = scaler.outputTextureUsage;
                }
            }
        } else {
            MTLFXTemporalScalerDescriptor *descriptor = [MTLFXTemporalScalerDescriptor new];
            descriptor.colorTextureFormat = g_formats[AMF_TEX_COLOR].metal;
            descriptor.depthTextureFormat = g_formats[AMF_TEX_DEPTH].metal;
            descriptor.motionTextureFormat = g_formats[AMF_TEX_MOTION].metal;
            descriptor.outputTextureFormat = g_formats[AMF_TEX_OUTPUT].metal;
            descriptor.inputWidth = renderWidth;
            descriptor.inputHeight = renderHeight;
            descriptor.outputWidth = outputWidth;
            descriptor.outputHeight = outputHeight;
            descriptor.autoExposureEnabled = YES;
            descriptor.requiresSynchronousInitialization = YES;
            if (@available(macOS 14.4, *)) {
                descriptor.reactiveMaskTextureEnabled = YES;
                descriptor.reactiveMaskTextureFormat = g_formats[AMF_TEX_REACTIVE].metal;
            }
            if (@available(macOS 26.0, *)) {
                if (metal4 && g_queue4) {
                    g_scaler = [descriptor newTemporalScalerWithDevice:g_device compiler:g_compiler4];
                    g_metal4 = g_scaler != nil;
                }
            }
            if (!g_scaler) g_scaler = [descriptor newTemporalScalerWithDevice:g_device];
            id<MTLFXTemporalScalerBase> scaler = g_scaler;
            if (scaler) {
                usage[AMF_TEX_COLOR] = scaler.colorTextureUsage;
                usage[AMF_TEX_DEPTH] = scaler.depthTextureUsage;
                usage[AMF_TEX_MOTION] = scaler.motionTextureUsage;
                usage[AMF_TEX_REACTIVE] = MTLTextureUsageShaderRead;
                usage[AMF_TEX_OUTPUT] = scaler.outputTextureUsage;
                usage[AMF_TEX_OUTPUT_B] = scaler.outputTextureUsage;
            }
        }
        if (!g_scaler) {
            amf_log("metalfx: no %s scaler for %dx%d -> %dx%d", denoise ? "denoised" : "temporal",
                    renderWidth, renderHeight, outputWidth, outputHeight);
            glBindTexture(GL_TEXTURE_RECTANGLE, (GLuint)previous);
            return 0;
        }
        int valid = 1;
        for (int which = 0; which < AMF_TEX_COUNT && valid; which++) {
            if (!denoise && which > AMF_TEX_OUTPUT && which != AMF_TEX_OUTPUT_B) continue;   // guides
            int output = which == AMF_TEX_OUTPUT || which == AMF_TEX_OUTPUT_B;
            valid = amf_image(which, output ? outputWidth : renderWidth, output ? outputHeight : renderHeight, usage[which]);
        }
        glBindTexture(GL_TEXTURE_RECTANGLE, (GLuint)previous);
        if (!valid) {
            amf_log("metalfx: creating the shared images failed");
            amf_release();
            return 0;
        }
        if (g_metal4) {
            if (@available(macOS 26.0, *)) {
                // A command buffer and allocator that encoded the previous scaler hang the GPU when
                // they encode a new one (tools/macos_test/metalfx_test.m reconfigures): fresh ones.
                g_allocator4 = [g_device newCommandAllocator];
                g_commandBuffer4 = [g_device newCommandBuffer];
                NSError *error = nil;
                MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new];
                descriptor.label = @"Aurora MetalFX images";
                id<MTLResidencySet> residency = [g_device newResidencySetWithDescriptor:descriptor error:&error];
                for (int which = 0; which < AMF_TEX_COUNT; which++)
                    if (g_textures[which]) [residency addAllocation:g_textures[which]];
                [residency commit];
                [(id<MTL4CommandQueue>)g_queue4 addResidencySet:residency];
                g_residency = residency;
            }
        }
        g_denoise = denoise;
        g_framesSinceConfigure = 0;
        g_renderWidth = renderWidth;
        g_renderHeight = renderHeight;
        amf_log("metalfx: %s scaler %dx%d -> %dx%d on %s", denoise ? "denoised" : "temporal", renderWidth, renderHeight,
                outputWidth, outputHeight, amf_backend());
    }
    return 1;
}

void amf_set_camera(const float *worldToView, const float *viewToClip)
{
    memcpy(&g_worldToView, worldToView, sizeof g_worldToView);
    memcpy(&g_viewToClip, viewToClip, sizeof g_viewToClip);
}

int amf_evaluate(float jitterX, float jitterY, float motionScaleX, float motionScaleY, int reset, int pipelined)
{
    if (!g_scaler || !amf_sync()) return 0;
    // Pipelined, into the output OpenGL is not about to sample; the first frames after a
    // configure (no finished output yet, and the scaler's GPU programs are built) wait.
    pipelined = pipelined && g_framesSinceConfigure >= 4;
    int output = pipelined ? (g_shownOutput == AMF_TEX_OUTPUT ? AMF_TEX_OUTPUT_B : AMF_TEX_OUTPUT) : g_shownOutput;
    @autoreleasepool {
        if (g_denoise) {
            if (@available(macOS 26.0, *)) {
                id<MTLFXTemporalDenoisedScalerBase> scaler = g_scaler;
                scaler.colorTexture = g_textures[AMF_TEX_COLOR];
                scaler.depthTexture = g_textures[AMF_TEX_DEPTH];
                scaler.motionTexture = g_textures[AMF_TEX_MOTION];
                scaler.reactiveMaskTexture = g_textures[AMF_TEX_REACTIVE];
                scaler.diffuseAlbedoTexture = g_textures[AMF_TEX_ALBEDO];
                scaler.specularAlbedoTexture = g_textures[AMF_TEX_SPECULAR];
                scaler.normalTexture = g_textures[AMF_TEX_NORMALS];
                scaler.roughnessTexture = g_textures[AMF_TEX_ROUGHNESS];
                scaler.outputTexture = g_textures[output];
                scaler.jitterOffsetX = jitterX;
                scaler.jitterOffsetY = jitterY;
                scaler.motionVectorScaleX = motionScaleX;
                scaler.motionVectorScaleY = motionScaleY;
                scaler.shouldResetHistory = reset != 0;
                scaler.depthReversed = NO;
                scaler.worldToViewMatrix = g_worldToView;
                scaler.viewToClipMatrix = g_viewToClip;
            }
        } else {
            id<MTLFXTemporalScalerBase> scaler = g_scaler;
            scaler.colorTexture = g_textures[AMF_TEX_COLOR];
            scaler.depthTexture = g_textures[AMF_TEX_DEPTH];
            scaler.motionTexture = g_textures[AMF_TEX_MOTION];
            if (@available(macOS 14.4, *)) scaler.reactiveMaskTexture = g_textures[AMF_TEX_REACTIVE];
            scaler.outputTexture = g_textures[output];
            scaler.inputContentWidth = g_renderWidth;
            scaler.inputContentHeight = g_renderHeight;
            scaler.jitterOffsetX = jitterX;
            scaler.jitterOffsetY = jitterY;
            scaler.motionVectorScaleX = motionScaleX;
            scaler.motionVectorScaleY = motionScaleY;
            scaler.reset = reset != 0;
            scaler.depthReversed = NO;
        }
        uint64_t value = ++g_eventValue;
        if (g_metal4) {
            if (@available(macOS 26.0, *)) {
                id<MTL4CommandBuffer> commandBuffer = g_commandBuffer4;
                [(id<MTL4CommandAllocator>)g_allocator4 reset];
                [commandBuffer beginCommandBufferWithAllocator:g_allocator4];
                if (g_denoise) [(id<MTL4FXTemporalDenoisedScaler>)g_scaler encodeToCommandBuffer:commandBuffer];
                else [(id<MTL4FXTemporalScaler>)g_scaler encodeToCommandBuffer:commandBuffer];
                [commandBuffer endCommandBuffer];
                id<MTL4CommandBuffer> buffers[1] = {commandBuffer};
                [(id<MTL4CommandQueue>)g_queue4 commit:buffers count:1];
                [(id<MTL4CommandQueue>)g_queue4 signalEvent:g_event value:value];
            }
        } else {
            id<MTLCommandBuffer> commandBuffer = [g_queue commandBuffer];
            if (g_denoise) {
                if (@available(macOS 26.0, *)) [(id<MTLFXTemporalDenoisedScaler>)g_scaler encodeToCommandBuffer:commandBuffer];
            } else [(id<MTLFXTemporalScaler>)g_scaler encodeToCommandBuffer:commandBuffer];
            [commandBuffer encodeSignalEvent:g_event value:value];
            [commandBuffer commit];
        }
        // Waiting here on every frame let macOS lower the GPU clock to its lowest state after
        // about 20 seconds of play (the GPU idles while the CPU waits, then the CPU while the GPU
        // catches up): pipelined, the wait moves to the next frame's amf_sync, by when it is done.
        if (pipelined) {
            g_pendingOutput = output;
            g_pendingValue = value;
            g_framesSinceConfigure++;
            return 1;
        }
        // The first frames after a configure also build the scaler's GPU programs: a timeout
        // there is no reason to give up.
        if (!amf_wait(value, g_framesSinceConfigure++ < 4 ? 30000 : 2000)) return 0;
    }
    return 1;
}

double amf_take_wait_ms(void)
{
    double mean = g_waitCount ? g_waitTotal / g_waitCount : 0.0;
    g_waitTotal = 0.0;
    g_waitCount = 0;
    return mean;
}

int amf_thermal_state(void)
{
    return (int)[[NSProcessInfo processInfo] thermalState];
}

int amf_memory_mb(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (int)(info.phys_footprint / (1024 * 1024));
}

int amf_decompressed_mb_per_s(void)
{
    static uint64_t lastPages, lastNs;
    vm_statistics64_data_t info;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&info, &count) != KERN_SUCCESS) return -1;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int rate = lastNs ? (int)((double)(info.decompressions - lastPages) * vm_kernel_page_size / (1024.0 * 1024.0)
                              / ((now - lastNs) / 1e9)) : 0;
    lastPages = info.decompressions;
    lastNs = now;
    return rate;
}

void amf_shutdown(void)
{
    @autoreleasepool { amf_release(); }
}
