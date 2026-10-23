#version 410 core
#extension GL_ARB_shader_image_load_store : enable
#extension GL_ARB_shader_image_size : enable

#define PIXELSIZE uPixelSize
#include "Fallback_inc.glsl"

// Additional information for fallback code within FXAA_inc.glsl
#define FXAA_PIXELSIZE uPixelSize
// Hytale FXAA config : Parameters are chosen based on the informations provided in FXAA_inc.glsl
#if USE_FXAA_HIGH_QUALITY
#define FXAA_QUALITY__PRESET 39
#else
#define FXAA_QUALITY__PRESET 20
#endif
#include "FXAA_inc.glsl"

uniform vec2 uPixelSize;
#include "DepthOfField_inc.glsl"
#include "AU_Tonemap.glsl"
#if AU_DEBUG || AU_LENSFLARE || AU_DLSS || AU_DLSS_FRAMEGEN || AU_ADAPTIVE_EXPOSURE || AU_METALFX
#include "SceneData_inc.glsl"
#include "AU_Common.glsl"
#endif
#if AU_LENSFLARE || AU_DLSS || AU_DLSS_FRAMEGEN || AU_METALFX
uniform sampler2D uHookDepth;   // DeferredFS linear depth (0..1 of the far plane), shared by the hook
#endif
#if AU_DLSS || AU_DLSS_FRAMEGEN || AU_METALFX
#include "Reconstruction_inc.glsl"
#include "AU_Temporal.glsl"
#endif
#if AU_DLSS || AU_DLSS_FRAMEGEN
// DLSS inputs: textures shared with the hook's Vulkan device (hook/aud_dlss.c). The hook
// upscales them with DLSS in place of Hytale's final scale-to-window draw.
layout(rgba16f) uniform writeonly image2D auDlssColor;
layout(r32f) uniform writeonly image2D auDlssDepth;
layout(rg16f) uniform writeonly image2D auDlssMotion;
uniform int uHookDlssActive;    // 1 only while the hook has the DLSS textures bound to units 2-4
uniform int uHookDlssResolve;
uniform vec4 uHookDlssViewport;
uniform sampler2D uHookDlssOutput;
uniform float uHookDlssSharpness;
#if AU_DLSS
layout(r8) uniform writeonly image2D auDlssResponsive;
#endif
#if AU_DLSS
// DLSS Ray Reconstruction's guide images (units 5-7), from AU_SurfaceGuides below.
layout(rgba8) uniform writeonly image2D auDlssAlbedo;
layout(rgba8) uniform writeonly image2D auDlssSpecular;
layout(rgba16f) uniform writeonly image2D auDlssNormals;
uniform int uHookDlssRR;           // 1 while the hook runs Ray Reconstruction (guides bound)
#endif
#endif
#if AU_METALFX
// MetalFX (hook/aud_metalfx.m), the macOS counterpart of DLSS: the hook draws this pass a second
// time into IOSurfaces it shares with Metal (uHookMfxPass 1; 2 adds the denoised scaler's guides),
// then resolves MetalFX's output into the window in place of Hytale's scale-to-window draw.
uniform int uHookMfxPass;
uniform int uHookDlssResolve;
uniform vec4 uHookDlssViewport;
uniform sampler2DRect uHookMfxOutput;
uniform float uHookDlssSharpness;
layout(location = 1) out vec4 auMfxDepth;
layout(location = 2) out vec4 auMfxMotion;
layout(location = 3) out vec4 auMfxReactive;
layout(location = 4) out vec4 auMfxAlbedo;
layout(location = 5) out vec4 auMfxSpecular;
layout(location = 6) out vec4 auMfxNormal;
layout(location = 7) out vec4 auMfxRoughness;
#endif
#if AU_DLSS || AU_METALFX
// DLSS Ray Reconstruction and MetalFX's denoised scaler also read what each pixel's surface is
// made of, worked out here from Hytale's G-buffer (shared by the hook).
#include "Deferred_inc.glsl"
#include "AU_Surface.glsl"
#include "AU_Material.glsl"
uniform sampler2D uHookGBuffer0;   // albedo + render flags
uniform sampler2D uHookGBuffer1;   // world-space normal (encoded)

// Average specular reflectance for a view angle (Karis' fit of the split-sum GGX lookup).
vec3 AU_EnvBRDF(vec3 f0, float roughness, float NdotV)
{
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

// The denoisers' guides for one pixel: diffuse and specular albedo, world-space normal with linear
// roughness in alpha. g0/g1: the G-buffer there, lin: its linear depth, posVS: its view position.
void AU_SurfaceGuides(vec4 g0, vec4 g1, float lin, vec3 posVS, out vec3 diffuseAlbedo, out vec3 specularAlbedo, out vec4 normalRough)
{
    vec3 guideNormal = decodeNormal(g1.rg);
    vec2 surfaceFootprint = AU_SurfaceFootprint(guideNormal, g0.rgb);
    // Sky: the defaults NVIDIA recommends (grey albedo, no specular, no normal).
    diffuseAlbedo = vec3(0.5);
    specularAlbedo = vec3(0.0);
    normalRough = vec4(0.0);
    if (lin >= 1.0) return;
    // The same material DeferredFS lit (include/AU_Material.glsl): dry gloss, metal,
    // ore crystals and the rain film / soaking.
    uint meta = uint(round(g0.a * 255.0));
    bool emissive = (meta & 2u) != 0u;
    bool foliage = !emissive && (meta & 1u) == 0u;
    AU_InitCommon();
    AU_MaterialData mat = AU_GetMaterial(g0.a, g0.rgb, guideNormal, g1.b, surfaceFootprint.y, emissive, foliage);
    vec3 normal = AU_MaterialReflectionNormal(guideNormal, mat);
    float roughness = 1.0 - AU_SpecularSmoothness(clamp(max(0.85 * mat.crystal, mat.smoothness), 0.0, 0.95), surfaceFootprint.x);
    vec3 nVS = mat3(ViewMatrix) * normal;
    float NdotV = clamp(dot(nVS, -normalize(posVS)), 0.0, 1.0);
    vec3 albedo = AU_MaterialSoakedAlbedo(mix(vec3(GetLuminance(g0.rgb)), g0.rgb, AU_ALBEDO_SATURATION) * AU_ALBEDO_MULT, mat);
    diffuseAlbedo = pow(clamp(albedo, 0.0, 1.0), vec3(2.2));
    specularAlbedo = AU_EnvBRDF(mat.metal > 0.5 ? diffuseAlbedo : vec3(0.04 + 0.02 * mat.crystal), roughness, NdotV);
    if (emissive) specularAlbedo = vec3(0.0);
    if (mat.metal > 0.5) diffuseAlbedo *= 0.55;
    normalRough = vec4(normal, roughness);
}
#endif
#if AU_METALFX
vec3 AU_ResolveFetch(vec2 uv) { return texture(uHookMfxOutput, uv * vec2(textureSize(uHookMfxOutput))).rgb; }
vec2 AU_ResolveSize() { return vec2(textureSize(uHookMfxOutput)); }
#elif AU_DLSS
vec3 AU_ResolveFetch(vec2 uv) { return texture(uHookDlssOutput, uv).rgb; }
vec2 AU_ResolveSize() { return vec2(textureSize(uHookDlssOutput, 0)); }
#endif
#if AU_LENSFLARE

// Lens flare (sun and moon).
float auAspect;
float auFovMult;
vec2 auTexCoord;

float BaseLens(vec2 lightPos, float size, float dist, float hardness)
{
    vec2 lensCoord = (auTexCoord + (lightPos * dist - 0.5)) * vec2(auAspect, 1.0);
    float shape = length(lensCoord.xy);
    float lens = clamp(1.0 - shape / (size * auFovMult), 0.0, 1.0 / hardness) * hardness;
    lens *= lens; lens *= lens;
    return lens;
}

float OverlapLens(vec2 lightPos, float size, float dista, float distb)
{
    return BaseLens(lightPos, size, dista, 2.0) * BaseLens(lightPos, size, distb, 2.0);
}

float PointLens(vec2 lightPos, float size, float dist)
{
    float lens = BaseLens(lightPos, size, dist, 1.5) + BaseLens(lightPos, size * 4.0, dist, 1.0) * 0.5;
    return lens * (0.5 + 0.5 * sunFactor);
}

float RingLensTransform(float lensFlare)
{
    return pow(1.0 - pow(1.0 - pow(lensFlare, 0.25), 10.0), 5.0);
}

float RingLens(vec2 lightPos, float size, float distA, float distB)
{
    float lensFlare1 = RingLensTransform(BaseLens(lightPos, size, distA, 1.0));
    float lensFlare2 = RingLensTransform(BaseLens(lightPos, size, distB, 1.0));
    float lensFlare = clamp(lensFlare2 - lensFlare1, 0.0, 1.0);
    lensFlare *= sqrt(lensFlare);
    lensFlare *= 1.0 - length(auTexCoord - lightPos - 0.5);
    return lensFlare;
}

void DoLensFlare(inout vec3 color, vec2 texCoord, float dither, sampler2D sceneTex)
{
    auTexCoord = texCoord;
    auAspect = ViewportSize.x / ViewportSize.y;
    auFovMult = ProjectionMatrix[1][1] / 1.37373871;
    // The sun by day, the moon by night (never the moon in daylight when the sun is behind).
    vec3 sunVecVS = normalize(mat3(ViewMatrix) * (sunVisibility > 0.5 ? sunVec : -sunVec));
    vec4 clipPosSun = ProjectionMatrix * vec4(sunVecVS + 0.001, 1.0);
    if (clipPosSun.w <= 0.0) return;   // behind the camera
    vec3 lightPos3 = clipPosSun.xyz / clipPosSun.w * 0.5;
    vec2 lightPos = lightPos3.xy;
    vec2 screenPosSun = lightPos3.xy + 0.5;

    // Occlusion: terrain around the sun's screen position (8 depth taps), plus
    // the sun's own brightness so it fades behind thick clouds.
    float flareFactor = 1.0;
    vec2 cScale = 40.0 / ViewportSize.xy;
    const vec2 offs[4] = vec2[4](vec2(1.0, 0.0), vec2(-1.0, 1.0), vec2(0.0, 1.0), vec2(1.0, 1.0));
    for (int i = 0; i < 4; i++) {
        vec2 cOffset = (offs[i] - dither) * cScale;
        if (texture(uHookDepth, screenPosSun + cOffset).r < 0.9999) flareFactor -= 0.125;
        if (texture(uHookDepth, screenPosSun - cOffset).r < 0.9999) flareFactor -= 0.125;
    }
    vec3 sunScene = textureLod(sceneTex, clamp(screenPosSun, vec2(0.0), vec2(1.0)), 3.0).rgb;
    flareFactor *= smoothstep(0.6, 1.2, GetLuminance(sunScene));
    float sunOcclusion = max0(flareFactor);   // terrain + cloud visibility of the sun

    float str = length(lightPos * vec2(auAspect, 1.0));
    str = pow(clamp(str * 8.0, 0.0, 1.0), 2.0) - clamp(str * 3.0 - 1.5, 0.0, 1.0);
    flareFactor *= str;
    flareFactor *= 0.65 - 0.4 * rainFactor;

    vec3 flare = (
        BaseLens(lightPos, 0.3, -0.45, 1.0) * vec3(2.2, 1.2, 0.1) * 0.07 +
        BaseLens(lightPos, 0.3,  0.10, 1.0) * vec3(2.2, 0.4, 0.1) * 0.03 +
        BaseLens(lightPos, 0.3,  0.30, 1.0) * vec3(2.2, 0.2, 0.1) * 0.04 +
        BaseLens(lightPos, 0.3,  0.50, 1.0) * vec3(2.2, 0.4, 2.5) * 0.05 +
        BaseLens(lightPos, 0.3,  0.70, 1.0) * vec3(1.8, 0.4, 2.5) * 0.06 +
        BaseLens(lightPos, 0.3,  0.90, 1.0) * vec3(0.1, 0.2, 2.5) * 0.07 +

        OverlapLens(lightPos, 0.08, -0.28, -0.39) * vec3(2.5, 1.2, 0.1) * 0.015 +
        OverlapLens(lightPos, 0.08, -0.20, -0.31) * vec3(2.5, 0.5, 0.1) * 0.010 +
        OverlapLens(lightPos, 0.12,  0.06,  0.19) * vec3(2.5, 0.2, 0.1) * 0.020 +
        OverlapLens(lightPos, 0.12,  0.15,  0.28) * vec3(1.8, 0.1, 1.2) * 0.015 +
        OverlapLens(lightPos, 0.12,  0.24,  0.37) * vec3(1.0, 0.1, 2.5) * 0.010 +

        PointLens(lightPos, 0.03, -0.55) * vec3(2.5, 1.6, 0.0) * 0.06 +
        PointLens(lightPos, 0.02, -0.40) * vec3(2.5, 1.0, 0.0) * 0.045 +
        PointLens(lightPos, 0.04,  0.43) * vec3(2.5, 0.6, 0.6) * 0.06 +
        PointLens(lightPos, 0.02,  0.60) * vec3(0.2, 0.6, 2.5) * 0.045 +
        PointLens(lightPos, 0.03,  0.67) * vec3(0.7, 1.1, 3.0) * 0.075 +

        RingLens(lightPos, 0.22, 0.44, 0.46) * vec3(0.10, 0.35, 2.50) * 1.5 +
        RingLens(lightPos, 0.15, 0.98, 0.99) * vec3(0.15, 0.40, 2.55) * 2.5
    );

    if (sunVisibility < 0.5) {
        // Moon: a faint, desaturated flare while it is up.
        flare = flare * 0.2 + GetLuminance(flare) * vec3(0.3, 0.4, 0.6);
        flare *= clamp01(1.0 - (SdotU + 0.1) * 5.0);
        flareFactor *= AU_LENSFLARE_I > 1.001 ? sqrt(AU_LENSFLARE_I) : AU_LENSFLARE_I;
    } else {
        flareFactor *= AU_LENSFLARE_I;
        flare *= clamp01((SdotU + 0.1) * 5.0);
    }
    flareFactor = max0(flareFactor);
    color = mix(color, vec3(1.0), clamp01(flare * flareFactor));

    // Sun glare: a soft camera-lens halo around the visible sun.
    if (sunVisibility > 0.5) {
        float sunDist = length((texCoord - screenPosSun) * vec2(auAspect, 1.0));
        float glare = pow(max0(1.0 - sunDist / 0.75), 3.0) * 0.18 + pow(max0(1.0 - sunDist / 0.18), 2.0) * 0.22;
        vec3 glareColor = mix(vec3(1.0, 0.85, 0.6), vec3(1.0, 0.97, 0.9), noonFactor);
        color = mix(color, glareColor, clamp01(glare * sunOcclusion * (1.0 - 0.7 * rainFactor) * AU_SUN_GLARE
                                               * clamp01((SdotU - 0.05) * 5.0)));
    }
}
#endif


//-------------------------------------------------------------------------------------------------------------------------
//                                  Shader Params
//-------------------------------------------------------------------------------------------------------------------------
uniform sampler2D uColorTexture;
uniform sampler2D uDistortionTexture;

uniform float uTime;
uniform float uDistortionAmplitude = 0.0;
uniform float uDistortionFrequency = 0.0;

#if DEBUG_TILES
uniform vec2 uDebugTileResolution;
#endif // DEBUG_TILES

uniform vec2 uColorBrightnessContrast;
uniform float uColorSaturation = 1.0;
uniform vec3 uColorFilter = vec3(1.0);
#define uColorBrightness uColorBrightnessContrast.x
#define uColorContrast   uColorBrightnessContrast.y

#if DOF_VERSION != 3
// dof version 1
uniform sampler2D uDepthTexture;

#if USE_LINEAR_Z
uniform float uFarClip = 1024.0f;
#else
uniform mat4 uProjectionMatrix;
#endif

uniform float uNearBlurry;
uniform float uNearSharp;
uniform float uFarSharp;
uniform float uFarBlurry;
#endif // DOF_VERSION == 1 || DOF_VERSION == 2 || DOF_VERSION == 3

#if DOF_VERSION == 0
uniform float uNearBlurMax;
uniform float uFarBlurMax;
#endif
#if DOF_VERSION == 1
// dof version 2
uniform sampler2D uBlurTexture;
#endif
#if DOF_VERSION == 2
// dof version 2bis
uniform sampler2D uNearBlurTexture;
uniform sampler2D uFarBlurTexture;
#endif
#if DOF_VERSION == 3
// dof version 3
uniform sampler2D uCoCTexture;
uniform sampler2D uCoCLowResTexture;
uniform sampler2D uNearCoCBlurredLowResTexture;
uniform sampler2D uNearFieldLowResTexture;
uniform sampler2D uFarFieldLowResTexture;
uniform sampler2D uSceneColorLowResTexturePoint;
#endif

#if USE_BLOOM
uniform sampler2D uBloomTexture;
uniform int uApplyBloom;
#endif

//-------------------------------------------------------------------------------------------------------------------------
//                                  In
//-------------------------------------------------------------------------------------------------------------------------
in vec2 fragTexCoords;

//-------------------------------------------------------------------------------------------------------------------------
//                                  Out
//-------------------------------------------------------------------------------------------------------------------------
layout(location = 0) out vec4 outColor;

//-------------------------------------------------------------------------------------------------------------------------

// Used to calculate overall brightness
// See http://stackoverflow.com/a/596241 and https://www.w3.org/TR/AERT#color-contrast
const vec3 BrightnessCoefficients = vec3(0.299, 0.587, 0.114);

const float Pi = 3.14159265;

// Cost on Intel GPU :
// full screen & sanity check (aka worst case): 0.7ms
// full screen & no sanity check: 0.5ms
// common scene & sanity check : 0.4ms
#define USE_DISTORTION_SANITY_CHECK 1

vec4 FXAA(sampler2D texture, vec2 texCoords, vec2 pixelSize)
{
#if USE_FXAA_HIGH_QUALITY
    //const float fxaaQualityEdgeThreshold = 0.15;
    const float fxaaQualityEdgeThreshold = 0.05;
#else
    //const float fxaaQualityEdgeThreshold = 0.33;
    const float fxaaQualityEdgeThreshold = 0.15;
#endif

    // NB : when using Screendoor Transparency, fxaaQualitySubpix should be 1.0
    const float fxaaQualitySubpix = 0.0;//1.0;
    const float fxaaQualityEdgeThresholdMin = 0.0;

    return FxaaPixelShader(texture, texCoords, pixelSize, fxaaQualitySubpix, fxaaQualityEdgeThreshold, fxaaQualityEdgeThresholdMin);
}

vec3 sharpen(in sampler2D tex, in vec2 coords, vec3 pixelColor, float strength)
{
    float dx = uPixelSize.x;
    float dy = uPixelSize.y;
    vec3 sum = vec3(0.0);
    sum += -strength * texture(tex, coords + vec2( -dx , 0.0)).rgb;
    sum += -strength * texture(tex, coords + vec2( 0.0, -dy)).rgb;
    sum += (4.0 * strength + 1.0) * pixelColor;
    sum += -strength * texture(tex, coords + vec2( 0.0, dy)).rgb;
    sum += -strength * texture(tex, coords + vec2( dx , 0.0)).rgb;

    return sum;
}

vec3 computeDepthOfField(out bool isSharp)
{
    vec3 dofColor;

    #if DOF_VERSION != 3
    #if USE_LINEAR_Z
        float depth = texture(uDepthTexture, fragTexCoords.xy).r;
        float linearDepth = depth * uFarClip;
    #else
        // TODO use a function that will be brought by ssao
        float depth = texture(uDepthTexture, fragTexCoords.xy).r * 2.0 - 1.0;
        float linearDepth = getLinearDepthFromDepthNDC(depth, uProjectionMatrix);
    #endif // USE_LINEAR_Z
    #endif

    #if DOF_VERSION == 0
        dofColor = DepthOfFieldNaive(uColorTexture, fragTexCoords, uPixelSize, linearDepth, uNearBlurry, uNearSharp, uFarSharp, uFarBlurry, uNearBlurMax, uFarBlurMax, isSharp);
    #else
    #if DOF_VERSION == 1
        dofColor = DepthOfFieldFast(uColorTexture, uBlurTexture, fragTexCoords, linearDepth, uNearBlurry, uNearSharp, uFarSharp, uFarBlurry, isSharp);
    #else
    #if DOF_VERSION == 2
        dofColor = DepthOfFieldFastBis(uColorTexture, uNearBlurTexture, uFarBlurTexture, fragTexCoords, linearDepth, uNearBlurry, uNearSharp, uFarSharp, uFarBlurry, isSharp);
    #else
    #if DOF_VERSION == 3
        dofColor = DepthOfFieldAdvanced(uSceneColorLowResTexturePoint, uCoCTexture, uCoCLowResTexture, uNearCoCBlurredLowResTexture, uNearFieldLowResTexture, uFarFieldLowResTexture, fragTexCoords, uPixelSize, isSharp);
    #endif
    #endif
    #endif
    #endif
    return dofColor;
}

//-------------------------------------------------------------------------------------------------------------------------

void main()
{
#if AU_DLSS || AU_METALFX
    if (uHookDlssResolve == 1) {
        vec2 resolveUV = uHookDlssViewport.z > 0.0
            ? (gl_FragCoord.xy - uHookDlssViewport.xy) / uHookDlssViewport.zw : fragTexCoords;
        vec2 outputPixel = 1.0 / AU_ResolveSize();
        vec3 resolved = AU_ResolveFetch(resolveUV);
        if (uHookDlssSharpness > 0.0) {
            vec3 north = AU_ResolveFetch(resolveUV + vec2(0.0, outputPixel.y));
            vec3 south = AU_ResolveFetch(resolveUV - vec2(0.0, outputPixel.y));
            vec3 east = AU_ResolveFetch(resolveUV + vec2(outputPixel.x, 0.0));
            vec3 west = AU_ResolveFetch(resolveUV - vec2(outputPixel.x, 0.0));
            vec3 low = min(resolved, min(min(north, south), min(east, west)));
            vec3 high = max(resolved, max(max(north, south), max(east, west)));
            resolved = clamp(resolved + (resolved - (north + south + east + west) * 0.25) * uHookDlssSharpness * 2.0, low, high);
        }
#if AU_ADAPTIVE_EXPOSURE
        resolved *= AU_AdaptiveExposure();
#endif
        DoTonemap(resolved);
#if AU_LENSFLARE
        AU_InitCommon();
        DoLensFlare(resolved, resolveUV, GetDither(gl_FragCoord.xy), uColorTexture);
#endif
        DoBSLColorSaturation(resolved);
#if AU_VIGNETTE
        DoVignette(resolved, resolveUV);
#endif
        outColor = vec4(clamp(resolved, 0.0, 1.0), 1.0);
        return;
    }
#endif
    vec4 color;
    vec2 texCoords = fragTexCoords;

#if USE_DISTORTION
    vec2 distortion = texture(uDistortionTexture, texCoords).rg;
#if USE_DISTORTION_SANITY_CHECK
    // sanity check - a bit expensive, but no choice!
    if (vec2(0.0) != texture(uDistortionTexture, texCoords + distortion).rg) texCoords += distortion;
#else
    texCoords += distortion;
#endif // USE_DISTORTION_SANITY_CHECK
#endif // USE_DISTORTION

    // Distortion effect
    // FIXME : later, this will be removed from here and integrated in a refraction / distortion rendering pass
    if (uDistortionAmplitude > 0.0)
    {
        vec2 distort = vec2(
            cos(texCoords.x * uDistortionFrequency * Pi + uTime),
            sin(texCoords.y * uDistortionFrequency * Pi + uTime));

        texCoords = clamp(texCoords + distort * uPixelSize * uDistortionAmplitude, 0.0, 1.0);
    }

    // used to disable FXAA on depth of field's blurry area
    bool isSharp = true;

#if USE_BLOOM  && (SUN_FB_POW || USE_SUNSHAFT)
    vec3 bloomColor = vec3(0);
    if(uApplyBloom == 1)
    {
        bloomColor = texture(uBloomTexture, texCoords.xy).rgb;
    }
#endif
// -------------------------------------------- DOF --------------------------------------------
    #if USE_DOF

        vec3 dofColor = computeDepthOfField(isSharp);

        color.rgb = isSharp ? color.rgb : dofColor;

    #endif // USE_DOF

// -------------------------------------------- FXAA --------------------------------------------
    #if USE_FXAA && !AU_DLSS && !AU_METALFX
        color.rgb = isSharp ? FXAA(uColorTexture, texCoords, uPixelSize).rgb : color.rgb;
    #if USE_SHARPEN
        // Especially useful after FXAA, to compensate the blur produced
        const float sharpenStrength = SHARPEN_STRENGTH;
        color.rgb = isSharp ? sharpen(uColorTexture, texCoords, color.rgb, sharpenStrength) : color.rgb;
    #endif // USE_SHARPEN
    #else
        color.rgb = isSharp ? texture(uColorTexture, texCoords).rgb : color.rgb;
    #endif


#if AU_SHARPENING > 0 && !AU_DLSS && !AU_METALFX
    // Image sharpening. Applied before Hytale's
    // temporal blend, which reuses its own output as history - sharpening after it would compound.
    if (isSharp) {
        float sharpenMult = 0.0125 * float(AU_SHARPENING);
        vec3 nb = texture(uColorTexture, texCoords + vec2(uPixelSize.x, 0.0)).rgb
                + texture(uColorTexture, texCoords - vec2(uPixelSize.x, 0.0)).rgb
                + texture(uColorTexture, texCoords + vec2(0.0, uPixelSize.y)).rgb
                + texture(uColorTexture, texCoords - vec2(0.0, uPixelSize.y)).rgb;
        color.rgb = max(color.rgb * (1.0 + 4.0 * sharpenMult) - nb * sharpenMult, vec3(0.0));
    }
#endif

    // ---- Aurora grading ----
    // Hytale's per-environment grading (saturation / colour filter), partially kept.
    float colorIntensity = dot(color.rgb, BrightnessCoefficients);
    vec3 hytaleGraded = mix(vec3(colorIntensity), color.rgb, uColorSaturation) * uColorFilter.rgb;
    color.rgb = mix(color.rgb, hytaleGraded, AU_KEEP_HYTALE_GRADING);

#if DISCARD_DARK
    if (colorIntensity == 0) discard;
#endif

    // The scene is in gamma space until here, then linearises, blooms and tonemaps.
    vec3 c = pow(max(color.rgb, vec3(0.0)), vec3(2.2));

    // Bloom (BloomSelectFS stores pow(linear / 128, 0.25)).
    #if USE_BLOOM && (SUN_FB_POW || USE_SUNSHAFT) && AU_BLOOM
    if (uApplyBloom == 1) {
        vec3 bloom = bloomColor * bloomColor;
        bloom = bloom * bloom * 128.0;
        c = mix(c, bloom, AU_BLOOM_STRENGTH);
    }
    #endif
    vec3 dlssHDR = c;
#if AU_METALFX
    if (uHookMfxPass > 0) {
        // MetalFX's inputs, as the DLSS ones below: the frame before exposure and tonemapping,
        // its depth, the camera motion (where each pixel's surface was last frame, in pixels) and
        // how much to trust this frame over the history (emissive, foliage, the hand).
        vec2 inputSize = uHookDlssViewport.zw;
        float lin = min(texture(uHookDepth, fragTexCoords).r, 1.0);
        vec3 posVS = AU_ViewPosition(fragTexCoords, lin * FarClip);
        vec4 previousClip = ReprojectionMatrix * vec4(posVS, lin >= 1.0 ? 0.0 : 1.0);
        vec4 currentClip = ProjectionMatrix * vec4(posVS, lin >= 1.0 ? 0.0 : 1.0);
        vec2 motion = vec2(0.0);
        if (lin * FarClip >= AU_NEAR_IGNORE && uHookHistoryValid != 0 && previousClip.w > 0.00001 && currentClip.w > 0.00001)
            motion = (previousClip.xy / previousClip.w - currentClip.xy / currentClip.w) * 0.5 * inputSize;
        float viewDepth = max(lin * FarClip, NearClip);
        outColor = vec4(dlssHDR, 1.0);
        auMfxDepth = vec4(lin >= 1.0 ? 1.0 : clamp(GetDepthHWFromLinearDepth(viewDepth, ProjectionMatrix), 0.0, 1.0));
        auMfxMotion = vec4(motion, 0.0, 0.0);
        vec4 surface = texture(uHookGBuffer0, fragTexCoords), surfaceNormal = texture(uHookGBuffer1, fragTexCoords);
        uint surfaceFlags = uint(round(surface.a * 255.0));
        float reactive = lin >= 1.0 ? 0.0 : (surfaceFlags & 2u) != 0u ? 0.8
            : (surfaceFlags & 1u) == 0u ? 0.5 : surfaceNormal.a < 0.5 ? 0.25 : 0.0;
        auMfxReactive = vec4(lin * FarClip < AU_NEAR_IGNORE ? 0.8 : reactive);
        if (uHookMfxPass == 2) {
            vec3 diffuseAlbedo, specularAlbedo;
            vec4 normalRough;
            AU_SurfaceGuides(surface, surfaceNormal, lin, posVS, diffuseAlbedo, specularAlbedo, normalRough);
            auMfxAlbedo = vec4(diffuseAlbedo, 1.0);
            auMfxSpecular = vec4(specularAlbedo, 1.0);
            auMfxNormal = vec4(normalRough.xyz, 0.0);
            auMfxRoughness = vec4(normalRough.w);
        }
        return;
    }
#endif
#if AU_ADAPTIVE_EXPOSURE
    c *= AU_AdaptiveExposure();
#endif
    DoTonemap(c);
#if AU_LENSFLARE
    AU_InitCommon();
    DoLensFlare(c, fragTexCoords, GetDither(gl_FragCoord.xy), uColorTexture);
#endif
    DoBSLColorSaturation(c);
#if AU_VIGNETTE
    DoVignette(c, fragTexCoords);
#endif
    outColor.rgb = clamp(c, 0.0, 1.0);
    outColor.a = 1.0;

#if AU_DEBUG
    {
        AU_InitCommon();
        vec2 fc = gl_FragCoord.xy;
        float top = ViewportSize.y - 60.0;
        int row = int((top - fc.y) / 40.0);
        float x = (fc.x - 60.0) / 900.0;
        if (fc.y < top && row >= 0 && row < 16 && x >= -0.4 && x <= 1.1) {
            float v = 0.0;
            vec3 cols[16] = vec3[16](vec3(1,0.2,0.2), vec3(0.2,1,0.2), vec3(0.3,0.5,1), vec3(1,1,0.2), vec3(0.2,1,1),
                                     vec3(1,0.3,1), vec3(1), vec3(1,0.6,0.1), vec3(1), vec3(0.6),
                                     vec3(1,0.2,0.2), vec3(0.2,1,0.2), vec3(0.3,0.5,1), vec3(1,1,0.2), vec3(0.2,1,1), vec3(1,0.3,1));
            vec3 col = cols[row];
            if (row == 0) v = SdotU;
            if (row == 1) v = sunVisibility;
            if (row == 2) v = noonFactor;
            if (row == 3) v = nightFactor;
            if (row == 4) v = rainFactor;
            if (row == 5) v = SceneBrightness.r;
            if (row == 6) v = length(SunPositionWS) * 0.5;
            if (row == 7) v = AmbientIntensity;
            if (row == 8) { col = uHookTopGradientColor.rgb; v = 1.0; }
            if (row == 9) {
                vec3 shL = -normalize(vec3(SunShadowMatrix[0][0][2], SunShadowMatrix[0][1][2], SunShadowMatrix[0][2][2]));
                v = dot(shL, normalize(SunPositionWS));
            }
            if (row == 10) v = SunLightColor.a;
            if (row == 11) v = GetLuminance(SunLightColor.rgb);
            if (row == 12) v = GetLuminance(AmbientFrontColor);
            if (row == 13) v = GetLuminance(AmbientBackColor);
            if (row == 14) v = GetLuminance(FogTopColor.rgb);
            if (row == 15) v = GetLuminance(SunColor.rgb);
            bool inBar = ((x >= 0.0 && x <= v) || (x < 0.0 && x >= v)) && mod(fc.y, 40.0) > 8.0;
            float tick = abs(fract(x * 4.0 + 0.5) - 0.5) * 3600.0 / 4.0;
            if (tick < 1.5) outColor.rgb = vec3(0.6);
            else if (inBar) outColor.rgb = v < 0.0 ? col * 0.5 : col;
            else outColor.rgb = vec3(0.05);
        }
    }
#endif

    // Debug view of potential Tiles

#if DEBUG_TILES
    //const ivec2 tileSize = ivec2(120, 125);
    ivec2 tileSize = ivec2(vec2(textureSize(uColorTexture, 0)) / uDebugTileResolution.xy);
    vec2 v = floor(mod(gl_FragCoord.xy, tileSize.xy));
    if(v.x == 0 || v.y == 0) outColor =  vec4(1);
#endif

#if AU_DLSS || AU_DLSS_FRAMEGEN
    if (uHookDlssActive == 1) {
        // The hook sizes the input images to this viewport. Not imageSize(): AMD's compiler
        // does not offer it to #version 410 shaders, and the RTX profiles switch DLSS on (#17).
        ivec2 inputSize = ivec2(uHookDlssViewport.zw);
        ivec2 pix = ivec2(gl_FragCoord.xy) - ivec2(uHookDlssViewport.xy);
        if (any(lessThan(pix, ivec2(0))) || any(greaterThanEqual(pix, inputSize))) return;
        // The finished frame, its depth and the camera motion (where each pixel's surface was
        // last frame, in pixels; the first-person hand moves with the camera).
        float lin = min(texture(uHookDepth, fragTexCoords).r, 1.0);
        vec3 posVS = AU_ViewPosition(fragTexCoords, lin * FarClip);
        vec4 previousClip = ReprojectionMatrix * vec4(posVS, lin >= 1.0 ? 0.0 : 1.0);
        vec4 currentClip = ProjectionMatrix * vec4(posVS, lin >= 1.0 ? 0.0 : 1.0);
        vec2 motion = vec2(0.0);
        if (lin * FarClip >= AU_NEAR_IGNORE && uHookHistoryValid != 0 && previousClip.w > 0.00001 && currentClip.w > 0.00001)
            motion = (previousClip.xy / previousClip.w - currentClip.xy / currentClip.w) * 0.5 * vec2(inputSize);
#if AU_DLSS
        imageStore(auDlssColor, pix, vec4(dlssHDR, 1.0));
#else
        imageStore(auDlssColor, pix, vec4(outColor.rgb, 1.0));
#endif
        float viewDepth = max(lin * FarClip, NearClip);
        float dlssDepth = lin >= 1.0 ? 1.0 : clamp(GetDepthHWFromLinearDepth(viewDepth, ProjectionMatrix), 0.0, 1.0);
#if AU_DLSS
        if (uHookDlssRR == 1) dlssDepth = viewDepth;
#endif
        imageStore(auDlssDepth, pix, vec4(dlssDepth));
        imageStore(auDlssMotion, pix, vec4(motion, 0.0, 0.0));
#if AU_DLSS
        vec4 responseSurface = texture(uHookGBuffer0, fragTexCoords);
        vec4 responseNormal = texture(uHookGBuffer1, fragTexCoords);
        uint responseFlags = uint(round(responseSurface.a * 255.0));
        float response = lin >= 1.0 ? 0.0 : (responseFlags & 2u) != 0u ? 0.8
            : (responseFlags & 1u) == 0u ? 0.5 : responseNormal.a < 0.5 ? 0.25 : 0.0;
        if (lin * FarClip < AU_NEAR_IGNORE) response = 0.8;
        imageStore(auDlssResponsive, pix, vec4(response));
        if (uHookDlssRR == 1) {
            vec3 diffuseAlbedo, specularAlbedo;
            vec4 normalRough;
            AU_SurfaceGuides(responseSurface, responseNormal, lin, posVS, diffuseAlbedo, specularAlbedo, normalRough);
            imageStore(auDlssAlbedo, pix, vec4(diffuseAlbedo, 1.0));
            imageStore(auDlssSpecular, pix, vec4(specularAlbedo, 1.0));
            imageStore(auDlssNormals, pix, normalRough);
        }
#endif
    }
#endif
}
