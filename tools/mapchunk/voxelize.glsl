#if AU_VOXEL_WORLD && !ALPHA_BLEND && !USE_SCENE_DATA_OVERRIDE
    auEmitterPositionWS = positionWS.xyz;
    // Aurora Shaders: record this block in the path tracer's voxel grid (AU_Voxel.glsl).
    // Every vertex of a block writes the same cell; the chunk origin is uModelMatrix's
    // camera-relative translation plus the camera position, the block from the vertex id.
    {
        ivec3 auBlockPosition = ivec3(vertDoubleSidedAndBlockId & 31, (vertDoubleSidedAndBlockId >> 5) & 31, (vertDoubleSidedAndBlockId >> 10) & 31);
        ivec3 auBlock = ivec3(floor(uModelMatrix[3].xyz + CameraPosition + 0.5)) + auBlockPosition;
        if (AU_VoxInWindow(auBlock, ivec3(floor(CameraPosition))))
        {
#if !ANIMATED && !AU_VOXEL_ATLAS
            // A block with no vertex on a corner of its cell is a small model (torch, rock,
            // flower pot) the rays may pass; slabs, stairs and grass with overhangs all have
            // corner vertices and count as solid.
            vec3 auLocal = vec3(vertPositionPacked) / 512.0 - vec3(blockPosition);
            vec3 auOff = abs(auLocal - round(auLocal));
            bool auCorner = max(auOff.x, max(auOff.y, auOff.z)) < 0.01
                         && all(greaterThan(auLocal, vec3(-0.01))) && all(lessThan(auLocal, vec3(1.01)));
            vec3 auN = abs(normal);
            bool auAxis = max(auN.x, max(auN.y, auN.z)) > 0.99;
#if ALPHA_TEST
            // Cut-out blocks: leaves and bushes (axis-aligned) are porous; cross-quad grass
            // and flowers (diagonal) are left out.
            bool auWrite = auAxis;
            uint auType = AU_VOX_POROUS;
#else
            bool auWrite = true;
            uint auType = AU_VOX_SOLID;
#endif
            if (auWrite)
            {
                ivec3 auCell = auBlock & AU_VOX_MASK;
                uint auTag = AU_VoxTag(auBlock) << 8;
                uint auMedium = 0u;
#if AU_SSS && AU_SSS_VOXEL == 1
                ivec3 auMaterialTile = ivec3(ivec2(fragTexCoords * vec2(textureSize(uTexture, 0).xy) / 32.0), int(fragAtlasPages.x + 0.5));
                vec2 auMaterial = round(texelFetch(uHookMaterials, auMaterialTile, 0).rg * 255.0);
                if (auMaterial == vec2(1.0, 6.0)) auMedium = AU_VOX_ICE;
#endif
                uint auGeometryFrame = (uint(uHookFrame) & 3u) << 14;
                uint auOld = imageLoad(auVoxGeo, auCell).r;
                // Some blocks are drawn twice (a solid block plus a cut-out overlay): solid wins,
                // or the two draws would flip the cell every frame.
                for (int auAttempt = 0; auAttempt < 8; auAttempt++) {
                    uint auOldType = (auOld & 0x3F00u) == auTag ? auOld & 3u : AU_VOX_UNKNOWN;
                    uint auNew = auOld;
                    if (auOldType < AU_VOX_SOLID)
                        auNew = auType | auTag | (auCorner ? 0u : AU_VOX_SMALL)
                            | ((auOld & 0x3f00u) == auTag ? auOld & 0xffff0008u : 0u);
                    else if (auType == AU_VOX_SOLID && auOldType == AU_VOX_POROUS)
                        auNew = (auOld & ~7u) | auType | (auCorner ? 0u : AU_VOX_SMALL);
                    else if (auType == auOldType && auCorner)
                        auNew = auOld & ~AU_VOX_SMALL;
                    auNew = (auNew & ~AU_VOX_GEOMETRY_FRAME_MASK) | auGeometryFrame;
                    auNew = (auNew & ~AU_VOX_ICE) | auMedium;
                    if (auNew == auOld) break;
                    uint auPrevious = imageAtomicCompSwap(auVoxGeo, auCell, auOld, auNew);
                    if (auPrevious == auOld) break;
                    auOld = auPrevious;
                }
            }
#endif
#if (AU_LOCAL_LIGHTS || AU_PT_LIGHTS) && DEFERRED
            vec4 auEmitterClip = ViewProjectionMatrix * vec4(vec3(auBlock) + 0.5 - CameraPosition, 1.0);
            float auEmitterReach = AU_LOCAL_LIGHT_RANGE + 1.0;
            vec2 auEmitterMargin = vec2(abs(ProjectionMatrix[0][0]), abs(ProjectionMatrix[1][1])) * auEmitterReach;
            if (auEmitterClip.w > -auEmitterReach && all(lessThanEqual(abs(auEmitterClip.xy), vec2(max(auEmitterClip.w, 0.0)) + auEmitterMargin))) {
            // Light sources: Hytale draws glowing faces (flames, crystals) FULLBRIGHT. The first
            // such vertex of a block this frame (frame stamp in the cell's top 16 bits) adds the
            // block to this frame's light list, with Hytale's light colour there.
            vec2 auAtlasSize = vec2(textureSize(uTexture, 0).xy);
            ivec3 auEmitterTile = ivec3(ivec2(fragTexCoords * auAtlasSize / 32.0), int(fragAtlasPages.x + 0.5));
            vec3 auGlow = AU_NativeEmission(auEmitterTile, tintColor);
            vec2 auTileCenter = (vec2(auEmitterTile.xy) * 32.0 + 16.0) / auAtlasSize;
            vec3 auTextureLight = textureLod(uTexture, vec3(auTileCenter, fragAtlasPages.x), 5.0).rgb * tintColor;
            float auTexturePeak = max(auTextureLight.r, max(auTextureLight.g, auTextureLight.b));
            vec3 auTextureTint = auTextureLight / max(auTexturePeak, 0.001);
            if (shadingMode == SHADING_FULLBRIGHT && max(glowColorAndSunlight.r, max(glowColorAndSunlight.g, glowColorAndSunlight.b)) > 0.25)
                auGlow = max(auGlow, auTextureTint);
            if (shadingMode == SHADING_REFLECTIVE) auGlow = max(auGlow, auTextureTint * AU_ORE_TORCH_RATIO * (AU_ORE_LIGHT / 8.0));
            AU_RecordEmitter(auBlock, auGlow);
            }
#endif
        }
    }
#endif
