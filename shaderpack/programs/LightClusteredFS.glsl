#version 410 core

// Aurora Shaders for Hytale - dynamic lights with shadows.
// Hytale lights each pixel from the point lights of its cluster grid (a torch in the hand,
// lanterns, glowing items and projectiles) by distance alone, through walls. With
// AU_DYNAMIC_SHADOWS each light also faces the surface (N.L from the G-buffer normal the hook
// shares) and is blocked by the terrain between them: one shadow ray per light through the voxel
// grid (AU_Voxel.glsl), aimed at a random point of a light-sized ball so the TAA averages it into
// a soft shadow. Players and mobs are not in the grid and cast none.

#include "Deferred_inc.glsl"
#include "Reconstruction_inc.glsl"
#include "SceneData_inc.glsl"
#include "AU_Settings.glsl"

uniform sampler2D uDepthTexture;
uniform mat4 uProjectionMatrix;
uniform float uFarClip;
#ifndef uLightGridResolution   // the scene data block carries them
uniform vec3 uLightGridResolution;
uniform vec3 uZSlicesParams;
#endif

#include "LightCluster_inc.glsl"

#ifndef INPUT_NORMALS_IN_WS
#define INPUT_NORMALS_IN_WS 1
#endif
#define AU_DYNAMIC_SHADOW_RAYS (AU_DYNAMIC_SHADOWS && AU_VOXEL_WORLD)
#if AU_DYNAMIC_SHADOWS
uniform sampler2D uHookGBuffer1;   // G-buffer normal (encoded), shared by the hook
#endif
#if AU_DYNAMIC_SHADOW_RAYS
uniform int uHookFrame;
#include "AU_Voxel.glsl"
#endif

in vec2 fragTexCoords;
in vec3 fragFrustumRay;

layout(location = 0) out vec3 outColor;

const float DynamicLightMultiplier = 3.0;

#if AU_DYNAMIC_SHADOW_RAYS
float AU_DynamicHash(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

// 1 when nothing in the grid stands between the surface and a point of the light, 0 otherwise
// (leaves and small models let part of the rays by). The light's own block is never tested.
float AU_DynamicLightShadow(vec3 originWS, vec3 lightWS, vec2 noise)
{
    float phi = noise.y * 6.2831853, cosTheta = noise.x * 2.0 - 1.0;
    vec3 offset = vec3(sqrt(1.0 - cosTheta * cosTheta) * vec2(cos(phi), sin(phi)), cosTheta) * (0.2 * AU_DYNAMIC_LIGHT_SIZE);
    vec3 toLight = lightWS + offset - originWS;
    float length2 = dot(toLight, toLight);
    if (length2 < 0.6 * 0.6) return 1.0;
    float distanceToLight = sqrt(length2);
    ivec3 block; vec3 normal; float t; uint cell;
    return AU_VoxTrace(originWS, toLight / distanceToLight, distanceToLight - 0.55, 48, noise.x, block, normal, t, cell) ? 0.0 : 1.0;
}
#endif

void main()
{
    float depth = texture(uDepthTexture, fragTexCoords).r;
    if (depth > 0.9999999) discard;
#if USE_LINEAR_Z
    vec3 positionVS = fragFrustumRay * depth;
#else
    vec4 projInfo = vec4(2.0 / uProjectionMatrix[0][0], -2.0 / uProjectionMatrix[1][1],
                         (1.0 - uProjectionMatrix[0][2]) / uProjectionMatrix[0][0], (1.0 + uProjectionMatrix[1][2]) / uProjectionMatrix[1][1]);
    vec3 positionVS = PositionFromDepthHW(depth, fragTexCoords, uProjectionMatrix, projInfo);
#endif
    int lightIndex;
    int pointLightCount;
    fetchClusterData(fragTexCoords, depth * uFarClip, lightIndex, pointLightCount);
    if (pointLightCount == 0) discard;

#if AU_DYNAMIC_SHADOWS
    vec3 normal = decodeNormal(texture(uHookGBuffer1, fragTexCoords).rg);
#if INPUT_NORMALS_IN_WS
    vec3 normalVS = mat3(ViewMatrix) * normal;
#else
    vec3 normalVS = normal;
#endif
#endif
#if AU_DYNAMIC_SHADOW_RAYS
    mat3 viewToWorld = mat3(InvViewMatrix);
    vec3 originWS = viewToWorld * (positionVS + normalVS * 0.05) + CameraPosition;
    vec2 noise = vec2(AU_DynamicHash(vec3(gl_FragCoord.xy, float(uHookFrame % 1024))),
                      AU_DynamicHash(vec3(gl_FragCoord.yx + 17.0, float(uHookFrame % 1024) + 0.5)));
#endif

    // Hytale's falloff per channel (each channel's value is its reach), the brightest light wins.
    vec3 dynamicLightColor = vec3(0.0);
    for (int pl = 0; pl < pointLightCount; pl++) {
        vec4 lightPosSize;
        vec3 lightColor;
        takeNextPointLight(lightIndex, lightPosSize, lightColor);
        vec3 toLight = lightPosSize.xyz - positionVS;
        float distanceToLight = length(toLight);
        if (distanceToLight > lightPosSize.w) continue;
        float scaled = distanceToLight * 0.1;   // as Hytale's lighting code
        vec3 light = vec3(getChannelLightNEW(scaled, lightColor.r), getChannelLightNEW(scaled, lightColor.g),
                          getChannelLightNEW(scaled, lightColor.b));
#if AU_DYNAMIC_SHADOWS
        float facing = dot(normalVS, toLight / max(distanceToLight, 0.0001));
        light *= mix(1.0, smoothstep(-0.15, 0.5, facing), AU_DYNAMIC_LIGHT_FACING);
#endif
#if AU_DYNAMIC_SHADOW_RAYS
        if (max(light.r, max(light.g, light.b)) > 0.002)
            light *= AU_DynamicLightShadow(originWS, viewToWorld * lightPosSize.xyz + CameraPosition, noise);
#endif
        dynamicLightColor = max(dynamicLightColor, light);
    }
    outColor = dynamicLightColor * DynamicLightMultiplier;
}
