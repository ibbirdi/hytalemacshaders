#version 410 core
// Aurora Shaders for Hytale - generic textured quads (also the sun and moon).

//-------------------------------------------------------------------------------------------------------------------------
//                                  Shader Params
//-------------------------------------------------------------------------------------------------------------------------
#if USE_TEXTURE_ARRAY
uniform sampler2DArray uTexture;
uniform int uPage = 0;
#else
uniform sampler2D uTexture;
#endif
uniform int uMipLevel = 0;
uniform vec4 uHookUpscale;   // hook: window size and sharpness while this draw scales the finished frame up

#if USE_COLOR_AND_OPACITY
uniform vec3 uColor;
uniform float uOpacity = 1.0;
#endif

//-------------------------------------------------------------------------------------------------------------------------
//                                  In
//-------------------------------------------------------------------------------------------------------------------------
in vec2 fragTexCoords;

//-------------------------------------------------------------------------------------------------------------------------
//                                  Out
//-------------------------------------------------------------------------------------------------------------------------
#if WRITE_ALPHA
layout (location = 0) out vec4 outColor;
#else
layout(location = 0) out vec3 outColor;
#endif

//-------------------------------------------------------------------------------------------------------------------------

#if !USE_TEXTURE_ARRAY
// Hytale's Render Scale below 100: the frame is drawn into the larger window here. Catmull-Rom
// from 4x4 texel fetches (whatever filtering the game's sampler has), clamped to the nearest 2x2
// texels against ringing, plus a little sharpening against the softness of the upscale.
vec3 AU_UpscaleTexel(ivec2 position, ivec2 size)
{
    return texelFetch(uTexture, clamp(position, ivec2(0), size - 1), 0).rgb;
}

vec3 AU_Upscale(vec2 uv, float sharpness)
{
    ivec2 size = textureSize(uTexture, 0);
    vec2 position = uv * vec2(size) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 f = position - vec2(base);
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec4 wx = vec4(w0.x, w1.x, w2.x, w3.x), wy = vec4(w0.y, w1.y, w2.y, w3.y);
    vec3 cubic = vec3(0.0), low = vec3(1e9), high = vec3(-1e9), linear = vec3(0.0);
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            vec3 texel = AU_UpscaleTexel(base + ivec2(x - 1, y - 1), size);
            cubic += texel * (wx[x] * wy[y]);
            if (x == 1 || x == 2) {
                if (y == 1 || y == 2) {
                    low = min(low, texel);
                    high = max(high, texel);
                    linear += texel * ((x == 1 ? 1.0 - f.x : f.x) * (y == 1 ? 1.0 - f.y : f.y));
                }
            }
        }
    }
    return clamp(cubic + (cubic - linear) * sharpness, low, high);
}
#endif

void main()
{
#if !USE_TEXTURE_ARRAY
    if (uHookUpscale.x > 0.0) {
        ivec2 source = textureSize(uTexture, 0);
        vec3 scaled = all(equal(source, ivec2(uHookUpscale.xy))) ? texelFetch(uTexture, ivec2(gl_FragCoord.xy), 0).rgb
                                                                   : AU_Upscale(fragTexCoords, uHookUpscale.z);
        outColor.rgb = scaled;
#if WRITE_ALPHA
        outColor.a = 1.0;
#endif
        return;
    }
#endif
#if USE_TEXTURE_ARRAY
    vec4 texel = textureLod(uTexture, vec3(fragTexCoords, float(uPage)), uMipLevel);
#else
    vec4 texel = textureLod(uTexture, fragTexCoords, uMipLevel);
#endif

#if USE_DISCARD
    if (texel.a == 0.0) discard;
#endif

#if USE_COLOR_AND_OPACITY
    vec4 color = vec4(texel.rgb * uColor.rgb, texel.a * uOpacity);
#else
    vec4 color = texel.rgba;
#endif

    outColor.rgb = color.rgb;
    // The sun and moon sprites sit at sky depth; make them HDR bright
    // so they stay brighter than the tonemapped sky.
    if (gl_FragCoord.z > 0.9995) outColor.rgb *= 4.0;

#if WRITE_ALPHA
    outColor.a = color.a;
#endif
}
