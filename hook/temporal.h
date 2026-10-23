typedef struct {
    GLuint buffer;
    int frame;
    void *mapped;
    ptrdiff_t mappedOffset, mappedSize;
    float scene[152];
} TemporalBuffer;

static TemporalBuffer g_temporalBuffers[8];
static unsigned g_temporalBufferCursor;
static int g_temporalHavePrevious;
static float g_previousSceneJitter[2];
static ULONGLONG g_temporalTick;
static int g_temporalLogCount;
static unsigned g_temporalGeneration = 1;   // changes whenever the temporal uniforms' values do
typedef void (APIENTRY *TemporalBufferData)(GLenum, ptrdiff_t, const void *, GLenum);
typedef void (APIENTRY *TemporalBufferSubData)(GLenum, ptrdiff_t, ptrdiff_t, const void *);
typedef TemporalBufferData PFN_glBufferData;
typedef TemporalBufferSubData PFN_glBufferSubData;
typedef void *(APIENTRY *PFN_glMapBufferRange)(GLenum, ptrdiff_t, ptrdiff_t, GLuint);
typedef GLboolean (APIENTRY *PFN_glUnmapBuffer)(GLenum);
static PFN_glMapBufferRange r_glMapBufferRange;
static PFN_glUnmapBuffer r_glUnmapBuffer;
static TemporalBufferData r_glBufferData;
static TemporalBufferSubData r_glBufferSubData;
static float g_previousGeometryJitter[2];
static float g_previousInverseProjection[16];

static int temporal_inverse(float *output, const float *input)
{
    double augmented[4][8];
    for (int row = 0; row < 4; row++)
        for (int column = 0; column < 8; column++)
            augmented[row][column] = column < 4 ? input[column * 4 + row] : (double)(column - 4 == row);
    for (int pivot = 0; pivot < 4; pivot++) {
        int best = pivot;
        for (int row = pivot + 1; row < 4; row++) if (fabs(augmented[row][pivot]) > fabs(augmented[best][pivot])) best = row;
        if (fabs(augmented[best][pivot]) < 1e-12) return 0;
        for (int column = 0; column < 8; column++) {
            double saved = augmented[pivot][column];
            augmented[pivot][column] = augmented[best][column];
            augmented[best][column] = saved;
        }
        double scale = augmented[pivot][pivot];
        for (int column = 0; column < 8; column++) augmented[pivot][column] /= scale;
        for (int row = 0; row < 4; row++) {
            if (row == pivot) continue;
            double factor = augmented[row][pivot];
            for (int column = 0; column < 8; column++) augmented[row][column] -= factor * augmented[pivot][column];
        }
    }
    for (int column = 0; column < 4; column++)
        for (int row = 0; row < 4; row++) output[column * 4 + row] = (float)augmented[row][column + 4];
    return 1;
}

static void temporal_cache(GLenum target, ptrdiff_t offset, ptrdiff_t size, const void *data)
{
    if (target != 0x8a11 || offset != 0 || size < (ptrdiff_t)sizeof(g_temporalScene) || !data) return;
    GLint buffer = 0;
    r_glGetIntegerv(0x8a28, &buffer);
    if (buffer <= 0) return;
    TemporalBuffer *record = NULL;
    for (int index = 0; index < 8; index++)
        if (g_temporalBuffers[index].buffer == (GLuint)buffer) record = &g_temporalBuffers[index];
    if (!record) record = &g_temporalBuffers[g_temporalBufferCursor++ % 8];
    record->buffer = (GLuint)buffer;
    record->frame = g_frame;
    memcpy(record->scene, data, sizeof(record->scene));
}

static void APIENTRY hook_glBufferData(GLenum target, ptrdiff_t size, const void *data, GLenum usage)
{
    temporal_cache(target, 0, size, data);
    r_glBufferData(target, size, data, usage);
}

static void *APIENTRY hook_glMapBufferRange(GLenum target, ptrdiff_t offset, ptrdiff_t size, GLuint flags)
{
    void *mapped = r_glMapBufferRange(target, offset, size, flags);
    if (mapped && target == 0x8a11 && (flags & 2u) && offset == 0 && size >= (ptrdiff_t)sizeof(g_temporalScene)) {
        GLint buffer = 0;
        r_glGetIntegerv(0x8a28, &buffer);
        TemporalBuffer *record = NULL;
        for (int index = 0; index < 8; index++)
            if (g_temporalBuffers[index].buffer == (GLuint)buffer) record = &g_temporalBuffers[index];
        if (!record) record = &g_temporalBuffers[g_temporalBufferCursor++ % 8];
        record->buffer = (GLuint)buffer;
        record->mapped = mapped;
        record->mappedOffset = offset;
        record->mappedSize = size;
    }
    return mapped;
}

static GLboolean APIENTRY hook_glUnmapBuffer(GLenum target)
{
    if (target == 0x8a11) {
        GLint buffer = 0;
        r_glGetIntegerv(0x8a28, &buffer);
        for (int index = 0; index < 8; index++) {
            TemporalBuffer *record = &g_temporalBuffers[index];
            if (record->buffer == (GLuint)buffer && record->mapped) {
                temporal_cache(target, record->mappedOffset, record->mappedSize, record->mapped);
                record->mapped = NULL;
            }
        }
    }
    return r_glUnmapBuffer(target);
}

static void APIENTRY hook_glBufferSubData(GLenum target, ptrdiff_t offset, ptrdiff_t size, const void *data)
{
    temporal_cache(target, offset, size, data);
    r_glBufferSubData(target, offset, size, data);
}

static int temporal_geometry(const ProgRec *program)
{
    static const char *names[] = {"MapChunkFS", "BlockyModelFS", "ParticleFS", "BeamFS", "SkyAndCloudsFS", "BasicFogFS", "TextFS"};
    for (int index = 0; index < (int)(sizeof(names) / sizeof(names[0])); index++)
        if (!strcmp(program->pname, names[index])) return 1;
    return 0;
}

static void temporal_uniforms(ProgRec *program)
{
    // Uniforms keep their values per program: send them once per change, not at every draw.
    unsigned sent = g_temporalGeneration * 2u + (g_postPresent != 0);
    if (program->temporalSent == sent) return;
    program->temporalSent = sent;
    if (program->giCompact) {
        if (program->locGIPreviousInverse >= 0) r_glUniformMatrix4fv(program->locGIPreviousInverse, 1, 0, g_previousInverseProjection);
        if (program->locGIPreviousDepth >= 0) r_glUniform2f(program->locGIPreviousDepth, g_temporalPreviousScene[58], g_temporalPreviousScene[62]);
    }
    if (program->locCurrentProjection >= 0) r_glUniformMatrix4fv(program->locCurrentProjection, 1, 0, g_temporalScene + 48);
    if (program->locPreviousVP >= 0) r_glUniformMatrix4fv(program->locPreviousVP, 1, 0, g_temporalPreviousScene + 64);
    if (program->locPreviousCamera >= 0) r_glUniform3f(program->locPreviousCamera, g_temporalPreviousScene[132], g_temporalPreviousScene[133], g_temporalPreviousScene[134]);
    if (program->locSceneJitter >= 0) r_glUniform2f(program->locSceneJitter, g_sceneJitter[0], g_sceneJitter[1]);
    if (program->locPreviousJitter >= 0) r_glUniform2f(program->locPreviousJitter, g_previousSceneJitter[0], g_previousSceneJitter[1]);
    if (program->locGeometryJitter >= 0) r_glUniform2f(program->locGeometryJitter, g_jitterNdc[0], g_jitterNdc[1]);
    if (program->locPreviousGeometryJitter >= 0) r_glUniform2f(program->locPreviousGeometryJitter, g_previousGeometryJitter[0], g_previousGeometryJitter[1]);
    if (program->locHistoryValid >= 0) r_glUniform1i(program->locHistoryValid, g_temporalValid);
    if (program->locJitter >= 0) {
        int jittered = program->temporalGeometry && !g_postPresent;
        r_glUniform2f(program->locJitter, jittered ? g_jitterNdc[0] : 0.0f, jittered ? g_jitterNdc[1] : 0.0f);
    }
}

static void temporal_prepare(ProgRec *program)
{
    if (!program->extrasChecked) return;
    if (g_temporalFrame != g_frame && (program->temporalGeometry || !strcmp(program->pname, "DeferredFS"))) {
        GLuint block = r_glGetUniformBlockIndex(g_curProg, "uboSceneDataBlock");
        typedef void (APIENTRY *GetBlockInteger)(GLuint, GLuint, GLenum, GLint *);
        typedef void (APIENTRY *GetIndexedInteger)(GLenum, GLuint, GLint *);
        typedef void (APIENTRY *GetBufferBytes)(GLenum, ptrdiff_t, ptrdiff_t, void *);
        typedef void (APIENTRY *BindBuffer)(GLenum, GLuint);
        static GetBlockInteger getBlock;
        static GetIndexedInteger getIndexed;
        static GetBufferBytes getBytes;
        static BindBuffer bind;
        if (!getBlock) {
            getBlock = (GetBlockInteger)real_wglGetProcAddress("glGetActiveUniformBlockiv");
            getIndexed = (GetIndexedInteger)real_wglGetProcAddress("glGetIntegeri_v");
            getBytes = (GetBufferBytes)real_wglGetProcAddress("glGetBufferSubData");
            bind = (BindBuffer)real_wglGetProcAddress("glBindBuffer");
        }
        if (block == GL_INVALID_INDEX || !getBlock || !getIndexed || !getBytes || !bind) return;
        GLint binding = 0, buffer = 0;
        getBlock(g_curProg, block, 0x8a3f, &binding);
        getIndexed(0x8a28, (GLuint)binding, &buffer);
        if (buffer <= 0) return;
        float scene[152];
        int cached = 0;
        for (int index = 0; index < 8; index++)
            if (g_temporalBuffers[index].buffer == (GLuint)buffer && g_temporalBuffers[index].frame == g_frame) {
                memcpy(scene, g_temporalBuffers[index].scene, sizeof(scene)); cached = 1; break;
            }
        if (!cached) {
            GLint previousBuffer;
            r_glGetIntegerv(0x8a28, &previousBuffer);
            bind(0x8a11, (GLuint)buffer);
            getBytes(0x8a11, 0, sizeof(scene), scene);
            bind(0x8a11, (GLuint)previousBuffer);
        }
        if (!isfinite(scene[48]) || fabsf(scene[48]) < 0.001f || scene[144] <= 0.0f) return;
        float effectiveProjection[16] = {0};
        for (int column = 0; column < 4; column++)
            for (int row = 0; row < 4; row++)
                for (int axis = 0; axis < 4; axis++)
                    effectiveProjection[column * 4 + row] += scene[64 + axis * 4 + row] * scene[80 + column * 4 + axis];
        memcpy(scene + 48, effectiveProjection, sizeof(effectiveProjection));
        ULONGLONG tick = GetTickCount64();
        g_temporalValid = g_temporalHavePrevious && tick - g_temporalTick < 500;
        float distance2 = 0.0f, direction = 0.0f;
        for (int axis = 0; axis < 3; axis++) {
            float difference = scene[132 + axis] - g_temporalScene[132 + axis];
            distance2 += difference * difference;
            direction += scene[136 + axis] * g_temporalScene[136 + axis];
        }
        if (distance2 > 256.0f || direction < 0.5f || fabsf(scene[48] - g_temporalScene[48]) > 0.05f
            || scene[140] != g_temporalScene[140] || scene[141] != g_temporalScene[141]) g_temporalValid = 0;
        memcpy(g_temporalPreviousScene, g_temporalHavePrevious ? g_temporalScene : scene, sizeof(scene));
        if (!temporal_inverse(g_previousInverseProjection, g_temporalPreviousScene + 64)) g_temporalValid = 0;
        memcpy(g_previousSceneJitter, g_sceneJitter, sizeof(g_sceneJitter));
        memcpy(g_previousGeometryJitter, g_jitterNdc, sizeof(g_jitterNdc));
        memcpy(g_temporalScene, scene, sizeof(scene));
        jitter_next_frame();
        float engineX = -scene[56], engineY = -scene[57];
        if (fabsf(engineX) > 0.0000001f || fabsf(engineY) > 0.0000001f) {
            g_jitterNdc[0] = g_jitterNdc[1] = 0.0f;
        }
        g_sceneJitter[0] = engineX + g_jitterNdc[0];
        g_sceneJitter[1] = engineY + g_jitterNdc[1];
#if AU_HAS_UPSCALER
        g_jitterPx[0] = g_sceneJitter[0] * g_dlssW * 0.5f;
        g_jitterPx[1] = g_sceneJitter[1] * g_dlssH * 0.5f;
        upscaler_set_camera(scene + 32, scene + 48);
        if (!g_temporalValid) g_dlssReset = 2;
#endif
        g_temporalHavePrevious = 1;
        g_temporalFrame = g_frame;
        g_temporalGeneration++;
        g_temporalTick = tick;
        if (g_temporalLogCount++ < 3) logf_("AA scene: %s cached=%d size=%.0fx%.0f jitter=(%.7f, %.7f) history=%d", program->pname,
                                          cached, scene[140], scene[141], g_sceneJitter[0], g_sceneJitter[1], g_temporalValid);
    }
    temporal_uniforms(program);
}
