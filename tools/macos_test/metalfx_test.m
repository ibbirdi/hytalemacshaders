// The MetalFX bridge on this Mac's GPU, end to end: OpenGL renders a scene into the shared
// IOSurfaces, MetalFX upscales it, OpenGL reads the result back.
//
// The scene is a pair of sharp edges at sub-pixel positions (a vertical one in red, a horizontal
// one in green), drawn like the hook's jittered geometry: shifted by the frame's jitter. MetalFX
// places each frame's samples by the jitter it is told; told the wrong sign, it puts them on the
// wrong side of the edge and the converged edge comes out wide. Panning scenes do the same for
// the motion vectors. The score is the width of each edge's transition, in output pixels.
//
//   tools/macos_test/metalfx_test.sh                       (Metal 4 where available)
//   AURORA_METALFX_METAL4=0 tools/macos_test/metalfx_test.sh   (the original Metal queue)
//   AURORA_METALFX_BENCH=1,2056,1258 build/metalfx_test        (time one configuration)
#define GL_SILENCE_DEPRECATION
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../hook/aud_metalfx.h"

enum { RENDER = 96, OUTPUT = 144, FRAMES = 48 };

static GLuint g_program, g_inputs, g_readback;
static GLint g_edge, g_jitter, g_motion;

static void log_line(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    vprintf(format, arguments);
    va_end(arguments);
    putchar('\n');
}

static float halton(int index, int base)
{
    float fraction = 1.0f, result = 0.0f;
    for (; index > 0; index /= base) { fraction /= (float)base; result += fraction * (float)(index % base); }
    return result;
}

static GLuint shader(GLenum type, const char *source)
{
    GLuint object = glCreateShader(type);
    glShaderSource(object, 1, &source, NULL);
    glCompileShader(object);
    GLint compiled = 0;
    glGetShaderiv(object, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char message[2048] = {0};
        glGetShaderInfoLog(object, sizeof message - 1, NULL, message);
        fprintf(stderr, "shader: %s\n", message);
        exit(1);
    }
    return object;
}

static void setup_scene(int denoise)
{
    if (!g_program) {
        const char *vertex = "#version 410 core\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));"
                             "gl_Position=vec4(p*2.0-1.0,0.0,1.0);}";
        const char *fragment = "#version 410 core\nuniform vec2 uEdge;uniform vec2 uJitter;uniform vec2 uMotion;\n"
            "layout(location=0) out vec4 color;layout(location=1) out vec4 depth;layout(location=2) out vec4 motion;\n"
            "layout(location=3) out vec4 reactive;layout(location=4) out vec4 albedo;layout(location=5) out vec4 specular;"
            "layout(location=6) out vec4 normal;layout(location=7) out vec4 roughness;\n"
            "void main(){vec2 p=gl_FragCoord.xy;color=vec4(step(uEdge+uJitter,p),0.0,1.0);depth=vec4(0.5);"
            "motion=vec4(uMotion,0.0,0.0);reactive=vec4(0.0);albedo=vec4(1.0);specular=vec4(0.04);normal=vec4(0.0,0.0,1.0,0.0);roughness=vec4(0.8);}";
        g_program = glCreateProgram();
        glAttachShader(g_program, shader(GL_VERTEX_SHADER, vertex));
        glAttachShader(g_program, shader(GL_FRAGMENT_SHADER, fragment));
        glLinkProgram(g_program);
        g_edge = glGetUniformLocation(g_program, "uEdge");
        g_jitter = glGetUniformLocation(g_program, "uJitter");
        g_motion = glGetUniformLocation(g_program, "uMotion");
        GLuint vertexArray;
        glGenVertexArrays(1, &vertexArray);
        glBindVertexArray(vertexArray);
        glGenFramebuffers(1, &g_inputs);
        glGenFramebuffers(1, &g_readback);
    }
    static const int inputs[8] = {AMF_TEX_COLOR, AMF_TEX_DEPTH, AMF_TEX_MOTION, AMF_TEX_REACTIVE,
                                  AMF_TEX_ALBEDO, AMF_TEX_SPECULAR, AMF_TEX_NORMALS, AMF_TEX_ROUGHNESS};
    GLenum buffers[8];
    int count = denoise ? 8 : 4;
    glBindFramebuffer(GL_FRAMEBUFFER, g_inputs);
    for (int index = 0; index < 8; index++) {
        buffers[index] = GL_COLOR_ATTACHMENT0 + index;
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + index, GL_TEXTURE_RECTANGLE,
                               index < count ? amf_texture(inputs[index]) : 0, 0);
    }
    glDrawBuffers(count, buffers);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) { fprintf(stderr, "input framebuffer incomplete: 0x%x\n", status); exit(1); }
    glBindFramebuffer(GL_FRAMEBUFFER, g_readback);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, amf_texture(AMF_TEX_OUTPUT), 0);
    status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) { fprintf(stderr, "output framebuffer incomplete: 0x%x\n", status); exit(1); }
}

// Transition width of the converged edges (output pixels: pixels not clearly on either side,
// per row for the vertical edge and per column for the horizontal one). The signs multiply what
// the hook would pass; speed moves the edges (render pixels per frame), like a camera pan.
typedef struct { double x, y; } Width;
static Width run(float jitterSignX, float jitterSignY, float motionSignX, float motionSignY, float speedX, float speedY)
{
    const float startX = 31.3f, startY = 27.7f;
    float edgeX = startX, edgeY = startY;
    glUseProgram(g_program);
    for (int frame = 0; frame < FRAMES; frame++) {
        float jitterX = halton(1 + frame % 16, 2) - 0.5f, jitterY = halton(1 + frame % 16, 3) - 0.5f;
        edgeX = startX + speedX * frame;
        edgeY = startY + speedY * frame;
        glBindFramebuffer(GL_FRAMEBUFFER, g_inputs);
        glViewport(0, 0, RENDER, RENDER);
        glUniform2f(g_edge, edgeX, edgeY);
        glUniform2f(g_jitter, jitterX, jitterY);
        // The hook's motion: where each pixel's surface was last frame, minus where it is.
        glUniform2f(g_motion, -speedX, -speedY);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFlush();
        if (!amf_evaluate(jitterX * jitterSignX, jitterY * jitterSignY, motionSignX, motionSignY, frame == 0)) {
            fprintf(stderr, "evaluate failed\n");
            exit(1);
        }
    }
    static float pixels[OUTPUT * OUTPUT * 4];
    glBindFramebuffer(GL_FRAMEBUFFER, g_readback);
    glReadPixels(0, 0, OUTPUT, OUTPUT, GL_RGBA, GL_FLOAT, pixels);
    Width width = {0.0, 0.0};
    for (int y = 0; y < OUTPUT; y++)
        for (int x = 0; x < OUTPUT; x++) {
            float red = pixels[(y * OUTPUT + x) * 4], green = pixels[(y * OUTPUT + x) * 4 + 1];
            width.x += red > 0.05f && red < 0.95f;
            width.y += green > 0.05f && green < 0.95f;
        }
    width.x /= OUTPUT;
    width.y /= OUTPUT;
    return width;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    CGLPixelFormatAttribute attributes[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                            kCGLPFAAccelerated, (CGLPixelFormatAttribute)0};
    CGLPixelFormatObj pixelFormat = NULL;
    GLint formats = 0;
    CGLContextObj context = NULL;
    if (CGLChoosePixelFormat(attributes, &pixelFormat, &formats) || CGLCreateContext(pixelFormat, NULL, &context)
        || CGLSetCurrentContext(context)) {
        fprintf(stderr, "no OpenGL 4.1 context\n");
        return 1;
    }
    if (!amf_init(log_line)) { fprintf(stderr, "MetalFX unavailable\n"); return 1; }
    // AURORA_METALFX_BENCH=denoise,width,height: only time that configuration (for comparisons).
    const char *bench = getenv("AURORA_METALFX_BENCH");
    const char *metal4Choice = getenv("AURORA_METALFX_METAL4");   // 0: the original Metal queue
    int metal4 = !metal4Choice || *metal4Choice != '0';
    int benchDenoise = 0, benchWidth = 0, benchHeight = 0;
    if (bench && sscanf(bench, "%d,%d,%d", &benchDenoise, &benchWidth, &benchHeight) == 3) {
        if (!amf_configure(benchWidth, benchHeight, 4112, 2516, benchDenoise, metal4)) return 1;
        setup_scene(benchDenoise);
        glUseProgram(g_program);
        glBindFramebuffer(GL_FRAMEBUFFER, g_inputs);
        glViewport(0, 0, benchWidth, benchHeight);
        for (int round = 0; round < 3; round++) {
            double total = 0.0;
            for (int frame = 0; frame < 30; frame++) {
                glDrawArrays(GL_TRIANGLES, 0, 3);
                glFinish();
                double start = CFAbsoluteTimeGetCurrent();
                if (!amf_evaluate(0.25f, -0.25f, 1.0f, 1.0f, frame == 0 && round == 0)) return 1;
                total += CFAbsoluteTimeGetCurrent() - start;
            }
            printf("%s %s %dx%d: %.2f ms\n", benchDenoise ? "denoised" : "temporal", amf_backend(), benchWidth, benchHeight, total * 1000.0 / 30.0);
        }
        return 0;
    }
    int failures = 0;
    for (int denoise = 0; denoise <= amf_denoiser_available(); denoise++) {
        if (!amf_configure(RENDER, RENDER, OUTPUT, OUTPUT, denoise, metal4)) { fprintf(stderr, "configure failed\n"); return 1; }
        setup_scene(denoise);
        const char *name = denoise ? "denoised" : "temporal";
        Width right = run(1, 1, 1, 1, 0, 0), wrong = run(-1, -1, 1, 1, 0, 0);
        printf("%s %s: still scene, edge width with the bridge's jitter %.2f x %.2f px, opposite signs %.2f x %.2f px\n",
               name, amf_backend(), right.x, right.y, wrong.x, wrong.y);
        Width panX = run(1, 1, 1, 1, 1.37f, 0), panXWrong = run(1, 1, -1, 1, 1.37f, 0);
        Width panY = run(1, 1, 1, 1, 0, 1.37f), panYWrong = run(1, 1, 1, -1, 0, 1.37f);
        printf("%s %s: panning, edge width with the bridge's motion %.2f / %.2f px, opposite sign %.2f / %.2f px\n",
               name, amf_backend(), panX.x, panY.y, panXWrong.x, panYWrong.y);
        int valid = right.x < wrong.x && right.y < wrong.y && panX.x <= panXWrong.x && panY.y <= panYWrong.y;
        printf("%s: %s\n", name, valid ? "PASS" : "FAIL (the bridge's jitter or motion convention is wrong)");
        failures += !valid;
    }
    // Cost at the sizes the hook runs it: two thirds and half of a 4112x2516 window, upscaled to it.
    for (int denoise = 0; denoise <= amf_denoiser_available(); denoise++)
    for (int half = 0; half < 2; half++) {
        int width = half ? 2056 : 2755, height = half ? 1258 : 1686;
        if (!amf_configure(width, height, 4112, 2516, denoise, metal4)) { fprintf(stderr, "configure failed\n"); return 1; }
        setup_scene(denoise);
        glUseProgram(g_program);
        glBindFramebuffer(GL_FRAMEBUFFER, g_inputs);
        glViewport(0, 0, width, height);
        double total = 0.0;
        for (int frame = 0; frame < 40; frame++) {
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glFinish();
            double start = CFAbsoluteTimeGetCurrent();
            amf_evaluate(0.25f, -0.25f, 1.0f, 1.0f, frame == 0);
            if (frame >= 10) total += CFAbsoluteTimeGetCurrent() - start;
        }
        printf("%s %s: %dx%d -> 4112x2516 in %.2f ms per frame (GPU work and the wait)\n",
               denoise ? "denoised" : "temporal", amf_backend(), width, height, total * 1000.0 / 30.0);
    }
    amf_shutdown();
    return failures ? 1 : 0;
}
