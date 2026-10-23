#include "../../hook/hook.c"
#undef NDEBUG
#include <assert.h>
#include <ctype.h>
#ifdef __APPLE__
// macOS: a headless OpenGL 4.1 core context from CGL, and Apple's GLSL compiler.
#include <OpenGL/OpenGL.h>
static void *g_appleGL;
static PROC apple_gl_proc(const char *name) { return (PROC)dlsym(g_appleGL, name); }
#endif

#ifdef __APPLE__
// Apple's preprocessor rejects identifiers no #define names in #if lines, where other drivers read
// 0. The game's CPU defines name them all at run time; here the ones the test leaves out are 0.
static void define_missing(const char *source, Str *out)
{
    char seen[256][64];
    int count = 0;
    for (const char *line = source; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
        const char *text = line + strspn(line, " \t");
        if (strncmp(text, "#if ", 4) && strncmp(text, "#elif ", 6)) continue;
        const char *end = strchr(text, '\n');
        if (!end) end = text + strlen(text);
        const char *comment = strstr(text, "//");
        if (comment && comment < end) end = comment;
        for (const char *c = text + (text[1] == 'i' ? 3 : 5); c < end; ) {
            if (!(isalpha((unsigned char)*c) || *c == '_')) { c++; continue; }
            const char *start = c;
            while (c < end && (isalnum((unsigned char)*c) || *c == '_')) c++;
            size_t length = (size_t)(c - start);
            if (length >= 64 || (length == 7 && !strncmp(start, "defined", 7))) continue;
            char name[64], pattern[80];
            memcpy(name, start, length);
            name[length] = 0;
            snprintf(pattern, sizeof pattern, "#define %s", name);
            int known = 0;
            for (const char *hit = strstr(source, pattern); hit && !known; hit = strstr(hit + 1, pattern))
                known = !isalnum((unsigned char)hit[strlen(pattern)]) && hit[strlen(pattern)] != '_';
            for (int index = 0; index < count && !known; index++) known = !strcmp(seen[index], name);
            if (known || count >= 256) continue;
            strcpy(seen[count++], name);
            str_cstr(out, "#ifndef "); str_cstr(out, name); str_cstr(out, "\n#define "); str_cstr(out, name); str_cstr(out, " 0\n#endif\n");
        }
    }
}
#endif

// The sources as the hook hands them to the driver (on macOS with #extension lines hoisted).
static char *driver_source(char *source)
{
#ifdef __APPLE__
    Str hoisted = {0};
    hoist_extensions(source, &hoisted);
    free(source);
    char *body = strchr(hoisted.p, '\n');
    while (body && !strncmp(body + 1, "#extension", 10)) body = strchr(body + 1, '\n');
    if (!body) return hoisted.p;
    Str output = {0};
    str_add(&output, hoisted.p, (size_t)(body + 1 - hoisted.p));
    define_missing(hoisted.p, &output);
    str_cstr(&output, body + 1);
    free(hoisted.p);
    return output.p;
#else
    return source;
#endif
}

static char *override_number(char *source, const char *name, const char *number)
{
    char *end = NULL;
    char *token = find_define_value(source, name, &end);
    assert(token && end);
    Str output = {0};
    str_add(&output, source, (size_t)(token - source));
    str_cstr(&output, number);
    str_cstr(&output, end);
    free(source);
    return output.p;
}

static char *shader_source(const char *name)
{
    char relative[160];
    snprintf(relative, sizeof(relative), "programs/%s.glsl", name);
    char *original = read_file(relative, NULL);
    assert(original);
    Str output = {0};
    str_cstr(&output, "#version 410 core\n#define USE_FOG 1\n#define USE_LINEAR_Z 1\n#define USE_SSAO 1\n"
                      "#define USE_EDGE_AWARE_UPSAMPLING 0\n#define USE_DEFERRED_SHADOW 1\n"
                      "#define USE_DEFERRED_SHADOW_BLURRED 1\n#define INPUT_NORMALS_IN_WS 1\n"
                      "#define CASCADE_COUNT 1\n#define NEAR 1\n#define DEFERRED 1\n"
                      "#define ALPHA_BLEND 0\n#define USE_SCENE_DATA_OVERRIDE 0\n#define ANIMATED 0\n");
    str_cstr(&output, "#define MAX_NODES_COUNT 256\n#define FIRST_PERSON_VIEW 0\n#define ALPHA_TEST 0\n"
                      "#define SHADOW_VERSION 0\n#define USE_COMPRESSED_POSITION 1\n#define USE_FOLIAGE_CULLING 0\n");
    str_cstr(&output, "#define USE_MOOD_FOG 0\n#define USE_SMOOTH_NEAR_MOOD_FOG_COLOR 1\n#define SKY_VERSION 0\n");
    if (strstr(name, "ZOnlyChunk")) str_cstr(&output, "#define USE_BACKFACE_CULLING 0\n");
    str_cstr(&output, "#define EFFECT_WATER 4\n#define EFFECT_WATERENVIRONMENTCOLOR 5\n"
                      "#define EFFECT_WATERENVIRONMENTTRANSITION 6\n"
                      "#define SHADING_FLAT 1\n#define SHADING_FULLBRIGHT 2\n#define SHADING_REFLECTIVE 3\n");
    if (!strstr(name, "ZOnlyChunkVS")) str_cstr(&output, "#define EFFECT_WIND 1\n");
    expand(&output, original, 0);
    free(original);
    return driver_source(output.p);
}

static int check_source(const char *name, char *source)
{
    source = driver_source(source);
    GLuint shader = r_glCreateShader(strstr(name, "VS") ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER);
    const GLchar *pointer = source;
    r_glShaderSource(shader, 1, &pointer, NULL);
    r_glCompileShader(shader);
    GLint status = 0;
    r_glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char message[8192] = {0};
        r_glGetShaderInfoLog(shader, sizeof(message) - 1, NULL, message);
        fprintf(stderr, "FAIL %s: %s\n", name, message);
        FILE *failed = fopen("build/validation/failed.glsl", "wb");
        if (failed) { fwrite(source, 1, strlen(source), failed); fclose(failed); }
    }
    r_glDeleteShader(shader);
    free(source);
    return status != 0;
}

static int check_non_rtx_history(int lights, int spatial, int temporal, int tracing, int enabled)
{
    GLuint (APIENTRY *createProgram)(void) = (void *)real_wglGetProcAddress("glCreateProgram");
    void (APIENTRY *deleteProgram)(GLuint) = (void *)real_wglGetProcAddress("glDeleteProgram");
    void (APIENTRY *getProgramLog)(GLuint, GLsizei, GLsizei *, GLchar *) = (void *)real_wglGetProcAddress("glGetProgramInfoLog");
    char *fragment = shader_source("DeferredFS");
    fragment = override_number(fragment, "AU_PRESET", "1");
    fragment = override_number(fragment, "AU_LOCAL_LIGHTS", lights ? "1" : "0");
    fragment = override_number(fragment, "AU_GI_SPATIAL_FILTER", spatial ? "1" : "0");
    fragment = override_number(fragment, "AU_GI_TEMPORAL_FILTER", temporal ? "1" : "0");
    fragment = override_number(fragment, "AU_PATH_TRACING", tracing ? "1" : "0");
    fragment = override_number(fragment, "AU_SSGI_DENOISE", enabled ? "1" : "0");
    fragment = override_number(fragment, "AU_GI_DENOISER", "1");
    const char *vertex = "#version 410 core\nout vec2 fragTexCoords;out vec3 fragFrustumRay;void main(){vec2 corner=vec2(float(gl_VertexID&1),float(gl_VertexID>>1));fragTexCoords=corner;fragFrustumRay=vec3(corner*2-1,-1);gl_Position=vec4(corner*2-1,0,1);}";
    const char *sources[] = {vertex, fragment};
    GLuint program = createProgram();
    int valid = 1;
    for (int stage = 0; stage < 2; stage++) {
        GLuint shader = r_glCreateShader(stage ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER);
        r_glShaderSource(shader, 1, &sources[stage], NULL); r_glCompileShader(shader);
        GLint compiled = 0; r_glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) {
            char message[8192] = {0}; r_glGetShaderInfoLog(shader, sizeof message, NULL, message);
            fprintf(stderr, "FAIL Non-RTX history stage: %s\n", message);
            valid = 0;
        }
        r_glAttachShader(program, shader); r_glDeleteShader(shader);
    }
    if (valid) {
        r_glLinkProgram(program);
        GLint linked = 0; r_glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            char message[8192] = {0}; getProgramLog(program, sizeof message, NULL, message);
            fprintf(stderr, "FAIL Non-RTX linked history: %s\n", message);
            valid = 0;
        } else {
            int expected = lights && temporal && enabled;
#ifdef __APPLE__
            expected = 0;   // the macOS hook switches local lights and the GI history off (no image load/store)
#endif
            int history = r_glGetUniformLocation(program, "auGIHist") >= 0;
            int output = r_glGetUniformLocation(program, "auGIOutPos") >= 0;
            if (history != expected || output != expected || r_glGetUniformLocation(program, "auGIOutLight") >= 0) {
                fprintf(stderr, "FAIL Non-RTX local=%d spatial=%d temporal=%d PT=%d enabled=%d history=%d output=%d expected=%d\n",
                    lights, spatial, temporal, tracing, enabled, history, output, expected);
                valid = 0;
            }
        }
    }
    deleteProgram(program); free(fragment);
    return valid;
}

static int check_atmosphere_pair(int atmosphere, int mood, int sky)
{
    GLuint (APIENTRY *createProgram)(void) = (void *)real_wglGetProcAddress("glCreateProgram");
    void (APIENTRY *deleteProgram)(GLuint) = (void *)real_wglGetProcAddress("glDeleteProgram");
    GLuint program = createProgram();
    int valid = 1;
    for (int stage = 0; stage < 2; stage++) {
        char *source = shader_source(stage ? sky ? "SkyFS" : "CloudsFS" : "SkyAndCloudsVS");
        source = override_number(source, "USE_MOOD_FOG", mood ? "1" : "0");
        if (stage) source = override_number(source, "AU_BIOME_ATMOSPHERE", atmosphere ? "1" : "0");
        else source = override_number(source, "SKY_VERSION", sky ? "1" : "0");
        GLuint shader = r_glCreateShader(stage ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER);
        const GLchar *pointer = source;
        r_glShaderSource(shader, 1, &pointer, NULL); r_glCompileShader(shader);
        GLint compiled = 0; r_glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) {
            char message[8192] = {0}; r_glGetShaderInfoLog(shader, sizeof message, NULL, message);
            fprintf(stderr, "FAIL atmosphere linked stage: %s\n", message);
            valid = 0;
        }
        r_glAttachShader(program, shader); r_glDeleteShader(shader); free(source);
    }
    if (valid) {
        r_glLinkProgram(program);
        GLint linked = 0; r_glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            void (APIENTRY *getLog)(GLuint, GLsizei, GLsizei *, GLchar *) = (void *)real_wglGetProcAddress("glGetProgramInfoLog");
            char message[8192] = {0}; getLog(program, sizeof message, NULL, message);
            fprintf(stderr, "FAIL linked atmosphere sky=%d mood=%d native=%d: %s\n", sky, mood, atmosphere, message);
            valid = 0;
        } else if (atmosphere) {
            if (r_glGetUniformLocation(program, sky ? "uTopGradientColor" : "uColors") < 0
                || r_glGetUniformLocation(program, sky ? "uSunsetColor" : "uCloudsTextureCount") < 0) {
                fprintf(stderr, "FAIL native sky/cloud atmosphere inputs were optimized out\n");
                valid = 0;
            }
        }
    }
    deleteProgram(program);
    return valid;
}

// The generated ScreenVS (sky light cube) linked with DeferredFS, as the deferred pass does.
static int check_sky_light_pair(int sky, int model, int biome, int preset)
{
    GLuint (APIENTRY *createProgram)(void) = (void *)real_wglGetProcAddress("glCreateProgram");
    void (APIENTRY *deleteProgram)(GLuint) = (void *)real_wglGetProcAddress("glDeleteProgram");
    void (APIENTRY *getProgramLog)(GLuint, GLsizei, GLsizei *, GLchar *) = (void *)real_wglGetProcAddress("glGetProgramInfoLog");
    GLuint program = createProgram();
    int valid = 1;
    for (int stage = 0; stage < 2; stage++) {
        char *source = shader_source(stage ? "DeferredFS" : "ScreenVS");
        if (!stage) source = override_number(source, "USE_FAR_CORNERS", "1");
        source = override_number(source, "AU_SKY_LIGHTING", sky ? "1" : "0");
        source = override_number(source, "AU_ATMOSPHERE_MODEL", model ? "1" : "0");
        source = override_number(source, "AU_BIOME_ATMOSPHERE", biome ? "1" : "0");
        source = override_number(source, "AU_PRESET", preset == 1 ? "1" : "2");
        GLuint shader = r_glCreateShader(stage ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER);
        const GLchar *pointer = source;
        r_glShaderSource(shader, 1, &pointer, NULL); r_glCompileShader(shader);
        GLint compiled = 0; r_glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) {
            char message[8192] = {0}; r_glGetShaderInfoLog(shader, sizeof message, NULL, message);
            fprintf(stderr, "FAIL sky light %s sky=%d model=%d biome=%d preset=%d: %s\n", stage ? "DeferredFS" : "ScreenVS", sky, model, biome, preset, message);
            valid = 0;
        }
        r_glAttachShader(program, shader); r_glDeleteShader(shader); free(source);
    }
    if (valid) {
        r_glLinkProgram(program);
        GLint linked = 0; r_glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            char message[8192] = {0}; getProgramLog(program, sizeof message, NULL, message);
            fprintf(stderr, "FAIL sky light linked sky=%d model=%d biome=%d preset=%d: %s\n", sky, model, biome, preset, message);
            valid = 0;
        }
    }
    deleteProgram(program);
    return valid;
}

static int check_shadow_pair(int method, int shadow, int alpha, int textures)
{
    GLuint (APIENTRY *createProgram)(void) = (void *)real_wglGetProcAddress("glCreateProgram");
    void (APIENTRY *deleteProgram)(GLuint) = (void *)real_wglGetProcAddress("glDeleteProgram");
    void (APIENTRY *getProgramLog)(GLuint, GLsizei, GLsizei *, GLchar *) = (void *)real_wglGetProcAddress("glGetProgramInfoLog");
    GLuint program = createProgram();
    const char *names[] = {"ZOnlyChunkVS", "ZOnlyChunkFS"};
    char methodValue[8]; snprintf(methodValue, sizeof methodValue, "%d", method);
    int valid = 1;
    for (int stage = 0; stage < 2; stage++) {
        char *source = shader_source(names[stage]);
        source = override_number(source, "ALPHA_TEST", alpha ? "1" : "0");
        if (!stage) source = override_number(source, "SHADOW_VERSION", shadow ? "1" : "0");
        else {
            source = override_number(source, "AU_SSS_VOXEL", methodValue);
            source = override_number(source, "AU_SSS_TEXTURES", textures ? "1" : "0");
        }
        GLuint shader = r_glCreateShader(stage ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER);
        const GLchar *pointer = source;
        r_glShaderSource(shader, 1, &pointer, NULL); r_glCompileShader(shader);
        GLint compiled = 0; r_glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) {
            char message[8192] = {0}; r_glGetShaderInfoLog(shader, sizeof message, NULL, message);
            fprintf(stderr, "FAIL %s method=%d shadow=%d alpha=%d masks=%d: %s\n", names[stage], method, shadow, alpha, textures, message);
            valid = 0;
        }
        r_glAttachShader(program, shader); r_glDeleteShader(shader); free(source);
    }
    if (valid) {
        r_glLinkProgram(program);
        GLint linked = 0; r_glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            char message[8192] = {0}; getProgramLog(program, sizeof message, NULL, message);
            fprintf(stderr, "FAIL ZOnlyChunk linked stages: %s\n", message);
            valid = 0;
        }
    }
    deleteProgram(program);
    return valid;
}

int main(int argumentCount, char **arguments)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
#ifdef __APPLE__
    assert(argumentCount == 2);
    MultiByteToWideChar(CP_UTF8, 0, arguments[1], -1, g_packDir, MAX_PATH);
    CGLPixelFormatAttribute attributes[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                            kCGLPFAAccelerated, (CGLPixelFormatAttribute)0};
    CGLPixelFormatObj pixelFormat = NULL;
    GLint formats = 0;
    CGLContextObj context = NULL;
    if (CGLChoosePixelFormat(attributes, &pixelFormat, &formats) || !pixelFormat
        || CGLCreateContext(pixelFormat, NULL, &context) || CGLSetCurrentContext(context)) {
        fprintf(stderr, "No OpenGL 4.1 core context\n");
        return 1;
    }
    g_appleGL = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW);
    linux_sdl_getproc = apple_gl_proc;
    real_wglGetProcAddress = linux_gl_proc;
#else
    assert(argumentCount == 3);
    MultiByteToWideChar(CP_UTF8, 0, arguments[1], -1, g_packDir, MAX_PATH);
    HMODULE sdl = LoadLibraryA(arguments[2]);
    assert(sdl);
    bool (*initialize)(uint32_t) = (bool (*)(uint32_t))GetProcAddress(sdl, "SDL_Init");
    bool (*setAttribute)(int, int) = (bool (*)(int, int))GetProcAddress(sdl, "SDL_GL_SetAttribute");
    void *(*createWindow)(const char *, int, int, uint64_t) = (void *(*)(const char *, int, int, uint64_t))GetProcAddress(sdl, "SDL_CreateWindow");
    void *(*createContext)(void *) = (void *(*)(void *))GetProcAddress(sdl, "SDL_GL_CreateContext");
    bool (*loadGL)(const char *) = (bool (*)(const char *))GetProcAddress(sdl, "SDL_GL_LoadLibrary");
    const char *(*getError)(void) = (const char *(*)(void))GetProcAddress(sdl, "SDL_GetError");
    assert(initialize && setAttribute && createWindow && createContext && loadGL);
    if (!initialize(0x20)) { fprintf(stderr, "%s\n", getError()); return 1; }
    wchar_t systemPath[MAX_PATH];
    GetSystemDirectoryW(systemPath, MAX_PATH);
    wcscat(systemPath, L"\\opengl32.dll");
    char library[MAX_PATH * 3];
    WideCharToMultiByte(CP_UTF8, 0, systemPath, -1, library, sizeof(library), NULL, NULL);
    if (!loadGL(library)) { fprintf(stderr, "%s\n", getError()); return 1; }
    setAttribute(17, 4);
    setAttribute(18, 1);
    setAttribute(21, 1);
    void *window = createWindow("Aurora shader validation", 64, 64, 0x0a);
    assert(window);
    void *context = createContext(window);
    if (!context) { fprintf(stderr, "%s\n", getError()); return 1; }
    g_real = LoadLibraryW(systemPath);
    real_wglGetProcAddress = (PFN_wglGetProcAddress)GetProcAddress(g_real, "wglGetProcAddress");
#endif
    #define GET_GL(name) r_##name = (PFN_##name)real_wglGetProcAddress(#name); assert(r_##name)
    GET_GL(glCreateShader);
    GET_GL(glShaderSource);
    GET_GL(glCompileShader);
    GET_GL(glGetShaderiv);
    GET_GL(glGetShaderInfoLog);
    GET_GL(glDeleteShader);
    GET_GL(glAttachShader);
    GET_GL(glLinkProgram);
    GET_GL(glGetProgramiv);
    GET_GL(glGetUniformLocation);
    GET_GL(glUseProgram);
    GET_GL(glUniformMatrix4fv);
    GET_GL(glUniform2f);
    GET_GL(glUniform1i);
    GET_GL(glUniform1f);
    int tested = 0, failures = 0;
    for (int sunlight = 0; sunlight < 2; sunlight++)
    for (int preset = 1; preset <= 2; preset++)
    for (int method = 0; method < 3; method++)
    for (int program = 0; program < 5; program++) {
        const char *name = program == 4 ? "DeferredShadowFS" : program == 3 ? "PostEffectFS" : program == 2 ? "MapChunkFS" : program == 1 ? "SkyFS" : "DeferredFS";
        char *source = shader_source(name);
        source = override_number(source, "AU_POLISH_SUNLIGHT", sunlight ? "1" : "0");
        source = override_number(source, "AU_PRESET", preset == 1 ? "1" : "2");
        source = override_number(source, "AU_SSS_VOXEL", method == 2 ? "2" : method == 1 ? "1" : "0");
        source = override_number(source, "AU_PATH_TRACING", method == 1 ? "1" : "0");
        source = override_number(source, "AU_DLSS", method == 2 ? "1" : "0");
        source = override_number(source, "AU_GI_DENOISER", method == 2 ? "2" : "1");
        if (program == 2) {
            source = override_number(source, "ALPHA_BLEND", "1");
            source = override_number(source, "DEFERRED", "0");
        }
        failures += !check_source(name, source); tested++;
    }
    for (int polish = 0; polish < 2; polish++)
    for (int antialiasing = 0; antialiasing < 2; antialiasing++)
    for (int preset = 1; preset <= 2; preset++)
    for (int dlss = 0; dlss < 2; dlss++)
    for (int tracing = 0; tracing < 2; tracing++)
    for (int program = 0; program < 3; program++) {
        const char *name = program == 2 ? "MapChunkFS" : program ? "PostEffectFS" : "DeferredFS";
        char *source = shader_source(name);
        source = override_number(source, "AU_POLISH_ENABLE", polish ? "1" : "0");
        source = override_number(source, "AU_POLISH_SPECULAR_AA", antialiasing ? "1" : "0");
        source = override_number(source, "AU_PRESET", preset == 1 ? "1" : "2");
        source = override_number(source, "AU_DLSS", dlss ? "1" : "0");
        source = override_number(source, "AU_GI_DENOISER", dlss ? "2" : "1");
        source = override_number(source, "AU_PATH_TRACING", tracing ? "1" : "0");
        failures += !check_source(name, source); tested++;
    }
    for (int cascades = 1; cascades <= 4; cascades++)
    for (int linear = 0; linear < 2; linear++)
    for (int pcss = 0; pcss < 2; pcss++)
    for (int normals = 0; normals < 2; normals++)
    for (int screenSpace = 0; screenSpace < 2; screenSpace++) {
        char cascadeValue[8]; snprintf(cascadeValue, sizeof cascadeValue, "%d", cascades);
        char *source = shader_source("DeferredShadowFS");
        source = override_number(source, "CASCADE_COUNT", cascadeValue);
        source = override_number(source, "USE_LINEAR_Z", linear ? "1" : "0");
        source = override_number(source, "INPUT_NORMALS_IN_WS", normals ? "1" : "0");
        source = override_number(source, "AU_PCSS", pcss ? "1" : "0");
        source = override_number(source, "AU_CONTACT_SHADOWS", screenSpace ? "1" : "0");
        source = override_number(source, "AU_FAR_SHADOWS", screenSpace ? "1" : "0");
        Str flags = {0};
        str_cstr(&flags, "#version 410 core\n");
        str_cstr(&flags, normals ? "#define USE_NORMAL_BIAS 1\n#define USE_CLEAN_BACKFACES 1\n"
                                : "#define USE_NORMAL_BIAS 0\n#define USE_CLEAN_BACKFACES 0\n");
        expand(&flags, source, 0); free(source);
        failures += !check_source("Sunset shadow variants", flags.p); tested++;
    }
    for (int atmosphere = 0; atmosphere < 2; atmosphere++)
    for (int mood = 0; mood < 2; mood++)
    for (int sky = 0; sky < 2; sky++) {
        failures += !check_atmosphere_pair(atmosphere, mood, sky);
        tested += 2;
    }
    for (int sky = 0; sky < 2; sky++)
    for (int model = 0; model < 2; model++)
    for (int biome = 0; biome < 2; biome++)
    for (int preset = 1; preset <= 2; preset++) {
        failures += !check_sky_light_pair(sky, model, biome, preset);
        tested += 2;
    }
    for (int method = 0; method < 2; method++)
    for (int quality = 1; quality <= 3; quality++)
    for (int preset = 1; preset <= 2; preset++)
    for (int linear = 0; linear < 2; linear++) {
        if (!method && quality > 1) continue;
        char qualityValue[8]; snprintf(qualityValue, sizeof qualityValue, "%d", quality);
        char *source = shader_source("DeferredFS");
        source = override_number(source, "AU_AO_METHOD", method ? "1" : "0");
        source = override_number(source, "AU_GTAO_QUALITY", qualityValue);
        source = override_number(source, "AU_PRESET", preset == 1 ? "1" : "2");
        source = override_number(source, "USE_LINEAR_Z", linear ? "1" : "0");
        char label[100]; snprintf(label, sizeof(label), "GTAO method=%d quality=%d preset=%d linear=%d", method, quality, preset, linear);
        failures += !check_source(label, source); tested++;
    }
    for (int refined = 0; refined < 2; refined++)
    for (int preset = 1; preset <= 2; preset++)
    for (int puddles = 0; puddles < 2; puddles++) {
        char *source = shader_source("DeferredFS");
        source = override_number(source, "AU_SSR_REFINED", refined ? "1" : "0");
        source = override_number(source, "AU_PRESET", preset == 1 ? "1" : "2");
        source = override_number(source, "AU_RAIN_PUDDLES", puddles ? "1" : "0");
        char label[100]; snprintf(label, sizeof(label), "SSR refined=%d preset=%d puddles=%d", refined, preset, puddles);
        failures += !check_source(label, source); tested++;
    }
    for (int model = 0; model < 2; model++)
    for (int caustics = 0; caustics < 2; caustics++)
    for (int quality = 0; quality < 2; quality++) {
        char *source = shader_source("MapChunkFS");
        source = override_number(source, "DEFERRED", "0");
        source = override_number(source, "ALPHA_BLEND", "1");
        source = override_number(source, "AU_WATER_MODEL", model ? "1" : "0");
        source = override_number(source, "AU_WATER_CAUSTICS", caustics ? "1" : "0");
        source = override_number(source, "AU_DLSS", quality ? "1" : "0");
        char label[100]; snprintf(label, sizeof(label), "Water model=%d caustics=%d dlss=%d", model, caustics, quality);
        failures += !check_source(label, source); tested++;
    }
    // Sky and finishing extras: aurora, ground mist (deferred, sky, forward water), highlight
    // protection, white balance and adaptive exposure (deferred emission, post, DLSS resolve).
    const char *extraPrograms[] = {"DeferredFS", "SkyFS", "MapChunkFS", "PostEffectFS"};
    for (int program = 0; program < 4; program++)
    for (int aurora = 0; aurora < 2; aurora++)
    for (int mist = 0; mist < 3; mist++)
    for (int adapt = 0; adapt < 2; adapt++)
    for (int dlss = 0; dlss < 2; dlss++) {
        char *source = shader_source(extraPrograms[program]);
        source = override_number(source, "AU_AURORA", aurora ? "1" : "0");
        source = override_number(source, "AU_AURORA_STYLE", dlss ? "1" : "2");
        source = override_number(source, "AU_MIST", mist ? "1" : "0");
        source = override_number(source, "AU_MIST_SAMPLES", mist == 2 ? "16" : "8");
        source = override_number(source, "AU_ADAPTIVE_EXPOSURE", adapt ? "1" : "0");
        source = override_number(source, "AU_TM_HIGHLIGHT_PROTECT", adapt ? "0.6" : "0.0");
        source = override_number(source, "AU_WB_TEMPERATURE", adapt ? "0.4" : "0.0");
        source = override_number(source, "AU_DLSS", dlss ? "1" : "0");
        source = override_number(source, "AU_LENSFLARE", dlss ? "1" : "0");
        if (program == 2) {
            source = override_number(source, "DEFERRED", "0");
            source = override_number(source, "ALPHA_BLEND", "1");
        }
        char label[120]; snprintf(label, sizeof(label), "Extras %s aurora=%d mist=%d adapt=%d dlss=%d", extraPrograms[program], aurora, mist, adapt, dlss);
        failures += !check_source(label, source); tested++;
    }
    for (int fog = 0; fog < 2; fog++)
    for (int lights = 0; lights < 2; lights++)
    for (int preset = 1; preset <= 2; preset++)
    for (int samples = 0; samples < 2; samples++) {
        char *source = shader_source("DeferredFS");
        source = override_number(source, "AU_LIGHT_FOG", fog ? "1" : "0");
        source = override_number(source, "AU_LOCAL_LIGHTS", lights ? "1" : "0");
        source = override_number(source, "AU_PRESET", preset == 1 ? "1" : "2");
        source = override_number(source, "AU_LIGHT_FOG_SAMPLES", samples ? "8" : "4");
        char label[100]; snprintf(label, sizeof(label), "Light fog=%d lights=%d preset=%d samples=%d", fog, lights, preset, samples);
        failures += !check_source(label, source); tested++;
    }
    const char *skyLightPrograms[] = {"MapChunkFS", "DeferredShadowFS", "ScreenVS"};
    for (int program = 0; program < 3; program++)
    for (int sky = 0; sky < 2; sky++) {
        char *source = shader_source(skyLightPrograms[program]);
        source = override_number(source, "AU_SKY_LIGHTING", sky ? "1" : "0");
        if (program == 0) {
            source = override_number(source, "DEFERRED", "0");
            source = override_number(source, "ALPHA_BLEND", "1");
        }
        failures += !check_source(skyLightPrograms[program], source); tested++;
    }
    const char *cloudPrograms[] = {"CloudsFS", "DeferredShadowFS", "MapChunkFS"};
    for (int program = 0; program < 3; program++)
    for (int layers = 1; layers <= 2; layers++)
    for (int lighting = 0; lighting < 2; lighting++)
    for (int samples = 1; samples <= 2; samples++) {
        char *source = shader_source(cloudPrograms[program]);
        source = override_number(source, "AU_CLOUD_LAYERS", layers == 1 ? "1" : "2");
        source = override_number(source, "AU_CLOUD_LIGHTING", lighting ? "1" : "0");
        source = override_number(source, "AU_CLOUD_LIGHT_SAMPLES", samples == 1 ? "1" : "2");
        failures += !check_source(cloudPrograms[program], source); tested++;
    }
    const char *atmospherePrograms[] = {"DeferredFS", "SkyFS", "CloudsFS", "MapChunkFS", "PostEffectFS", "TemporalAAFS", "BlockyModelFS", "SkyAndCloudsVS"};
    for (int model = 0; model < 2; model++)
    for (int atmosphere = 0; atmosphere < 2; atmosphere++)
    for (int mood = 0; mood < 2; mood++)
    for (int dlss = 0; dlss < 2; dlss++)
    for (int program = 0; program < 8; program++) {
        char *source = shader_source(atmospherePrograms[program]);
        if (program != 7) source = override_number(source, "AU_ATMOSPHERE_MODEL", model ? "1" : "0");
        if (program != 7) source = override_number(source, "AU_BIOME_ATMOSPHERE", atmosphere ? "1" : "0");
        source = override_number(source, "USE_MOOD_FOG", mood ? "1" : "0");
        if (program != 7) {
            source = override_number(source, "AU_DLSS", dlss ? "1" : "0");
            source = override_number(source, "AU_GI_DENOISER", dlss ? "2" : "1");
        }
        if (program == 3) {
            source = override_number(source, "DEFERRED", "0");
            source = override_number(source, "ALPHA_BLEND", "1");
        }
        if (program == 7) source = override_number(source, "SKY_VERSION", "1");
        failures += !check_source(atmospherePrograms[program], source); tested++;
    }
    for (int lights = 0; lights < 2; lights++)
    for (int spatial = 0; spatial < 2; spatial++)
    for (int temporal = 0; temporal < 2; temporal++)
    for (int tracing = 0; tracing < 2; tracing++)
    for (int enabled = 0; enabled < 2; enabled++) {
        failures += !check_non_rtx_history(lights, spatial, temporal, tracing, enabled);
        tested++;
    }
    for (int preset = 1; preset <= 2; preset++)
    for (int tracing = 0; tracing < 2; tracing++)
    for (int lights = 0; lights < 2; lights++)
    for (int temporal = 0; temporal < 2; temporal++)
    for (int backend = 1; backend <= 2; backend++) {
        char *text = shader_source("DeferredFS");
        text = override_number(text, "AU_PRESET", preset == 1 ? "1" : "2");
        text = override_number(text, "AU_PATH_TRACING", tracing ? "1" : "0");
        text = override_number(text, "AU_LOCAL_LIGHTS", lights ? "1" : "0");
        text = override_number(text, "AU_GI_TEMPORAL_FILTER", temporal ? "1" : "0");
        text = override_number(text, "AU_GI_DENOISER", backend == 1 ? "1" : "2");
        char label[100]; snprintf(label, sizeof(label), "Deferred preset=%d PT=%d local=%d temporal=%d backend=%d", preset, tracing, lights, temporal, backend);
        failures += !check_source(label, text); tested++;
    }
    for (int taps = 1; taps <= 9; taps += taps == 1 ? 3 : 5) {
        char value[8]; snprintf(value, sizeof(value), "%d", taps);
        char *text = shader_source("DeferredFS");
        text = override_number(text, "AU_GI_HISTORY_TAPS", value);
        failures += !check_source("Original history taps", text); tested++;
    }
    for (int method = 0; method < 3; method++)
    for (int enabled = 0; enabled < 2; enabled++) {
        char *text = shader_source("DeferredFS");
        text = override_number(text, "AU_SSS", enabled ? "1" : "0");
        text = override_number(text, "AU_SSS_VOXEL", method ? "1" : "0");
        text = override_number(text, "AU_LOCAL_LIGHTS", "0");
        text = override_number(text, "AU_PATH_TRACING", "0");
        failures += !check_source("SSS isolated grid variants", text); tested++;
    }
    const char *programs[] = {"MapChunkVS", "MapChunkFS", "PostEffectFS", "TemporalAAFS", "BlockyModelFS"};
    for (int program = 0; program < 5; program++)
    for (int dlss = 0; dlss < 2; dlss++) {
        char *text = shader_source(programs[program]);
        text = override_number(text, "AU_DLSS", dlss ? "1" : "0");
        failures += !check_source(programs[program], text); tested++;
    }
    for (int array = 0; array < 2; array++)
    for (int alpha = 0; alpha < 2; alpha++) {
        Str text = {0};
        str_cstr(&text, "#version 410 core\n");
        str_cstr(&text, array ? "#define USE_TEXTURE_ARRAY 1\n" : "#define USE_TEXTURE_ARRAY 0\n");
        str_cstr(&text, alpha ? "#define WRITE_ALPHA 1\n" : "#define WRITE_ALPHA 0\n");
        char *body = read_file("programs/BasicFS.glsl", NULL);
        assert(body);
        expand(&text, body, 0);
        free(body);
        failures += !check_source("BasicFS scale-to-window", text.p); tested++;
    }
    for (int blend = 0; blend < 2; blend++) {
        char *text = shader_source("MapChunkFS");
        text = override_number(text, "DEFERRED", "0");
        text = override_number(text, "ALPHA_BLEND", blend ? "1" : "0");
        failures += !check_source("Forward native emission", text); tested++;
    }
    for (int method = 0; method < 3; method++)
    for (int textures = 0; textures < 2; textures++)
    for (int deferred = 0; deferred < 2; deferred++) {
        char methodValue[8]; snprintf(methodValue, sizeof methodValue, "%d", method);
        char *text = shader_source("MapChunkFS");
        text = override_number(text, "ALPHA_TEST", "1");
        text = override_number(text, "DEFERRED", deferred ? "1" : "0");
        text = override_number(text, "AU_SSS_VOXEL", methodValue);
        text = override_number(text, "AU_SSS_TEXTURES", textures ? "1" : "0");
        failures += !check_source("MapChunkFS foliage material masks", text); tested++;
    }
    for (int animated = 0; animated < 2; animated++)
    for (int deferred = 0; deferred < 2; deferred++) {
        char *vertex = shader_source("MapChunkVS");
        vertex = override_number(vertex, "ANIMATED", animated ? "1" : "0");
        vertex = override_number(vertex, "DEFERRED", deferred ? "1" : "0");
        failures += !check_source("MapChunkVS emitter variants", vertex); tested++;
        char *fragment = shader_source("MapChunkFS");
        fragment = override_number(fragment, "ANIMATED", animated ? "1" : "0");
        fragment = override_number(fragment, "DEFERRED", deferred ? "1" : "0");
        failures += !check_source("MapChunkFS emitter variants", fragment); tested++;
    }
    for (int deferred = 0; deferred < 2; deferred++)
    for (int firstPerson = 0; firstPerson < 2; firstPerson++) {
        char *text = shader_source("BlockyModelFS");
        text = override_number(text, "DEFERRED", deferred ? "1" : "0");
        text = override_number(text, "FIRST_PERSON_VIEW", firstPerson ? "1" : "0");
        failures += !check_source("BlockyModelFS emitter variants", text); tested++;
    }
    for (int method = 0; method < 3; method++)
    for (int shadow = 0; shadow < 2; shadow++)
    for (int alpha = 0; alpha < 2; alpha++)
    for (int textures = 0; textures < 2; textures++) {
        failures += !check_shadow_pair(method, shadow, alpha, textures);
        tested += 2;
    }
    menu_load();
    const char *qualityPrograms[] = {"DeferredFS", "DeferredShadowFS", "CloudsFS", "MapChunkVS", "MapChunkFS", "PostEffectFS", "TemporalAAFS", "BlockyModelFS"};
    for (int profile = 0; profile < AU_BUILTIN_PROFILES; profile++) {
        menu_profile_builtin(profile);
        for (int program = 0; program < 9; program++) {
            const char *name = qualityPrograms[program < 8 ? program : 4];
            char *source = shader_source(name);
            for (int index = 0; index < g_nMo; index++) {
                MenuOpt *option = &g_mo[index];
                if (!option->present || strncmp(option->define, "AU_", 3)) continue;
                char value[32]; format_value(option, option->value, value, sizeof(value));
                source = override_number(source, option->define, value);
            }
            if (program == 8) {
                source = override_number(source, "ALPHA_BLEND", "1");
                source = override_number(source, "DEFERRED", "0");
            }
            char label[100]; snprintf(label, sizeof(label), "Quality profile %d %s%s", profile, name, program == 8 ? " forward" : "");
            failures += !check_source(label, source); tested++;
        }
    }
    printf("GPU GLSL: %d variants, %d failures\n", tested, failures);
    return failures ? 1 : 0;
}
