// Aurora Shaders for Hytale - settings.
// Saving this file hot-reloads every shader in the game.

#ifndef AU_SETTINGS
#define AU_SETTINGS

// ---- Preset --------------------------------------------------------------------------
// 1 = Standard
// 2 = RTX: + screen-space global illumination, material-specific reflections,
//          more shadow / light shaft / cloud samples
#define AU_PRESET 2

// ---- General -------------------------------------------------------------------------
#define AU_MENU_KEY 36
#define AU_SUN_MAX_ELEVATION 0.92   // sin(max sun elevation) of Hytale's sun path, maps time-of-day factors
#define AU_SCREEN_BRIGHTNESS 1.0    // Minecraft "brightness" slider equivalent (0 = moody, 1 = bright)
#define AU_TWILIGHT_SHIFT 0.10      // keeps daylight up longer to fit Hytale's long dusk
#define AU_SUNSET_SHIFT 0.0         // sun height (sin) offset for the sunset colour palette
#define AU_POLISH_ENABLE 1
#define AU_POLISH_TEXTURE_DETAIL 0.7
#define AU_POLISH_ROUGHNESS 0.35
#define AU_POLISH_SPECULAR_AA 1
#define AU_POLISH_AMBIENT 0.4
#define AU_POLISH_FOLIAGE_MATTE 0.65
#define AU_POLISH_SUNLIGHT 1
#define AU_POLISH_SKY_FILL 0.65
#define AU_SKY_LIGHTING 0
#define AU_SKY_LIGHT_GROUND 0.35
#define AU_SKY_LIGHT_STRENGTH 1.0
#define AU_POLISH_SUN_COLOUR 0.5
#define AU_POLISH_SUN_HIGHLIGHTS 0.6
#define AU_POLISH_FOLIAGE_SUN 0.65
#define AU_POLISH_SUN_BOUNCE 1.0
#define AU_POLISH_SUN_SHADOWS 1
#define AU_POLISH_SUN_DIAMETER 0.75
#define AU_POLISH_CONTACT_WEIGHT 0.85

// ---- Lighting ------------------------------------------------------------------------
#define AU_ALBEDO_MULT 0.78          // Hytale textures are painted brighter than Minecraft's
#define AU_ALBEDO_SATURATION 0.92
#define AU_SIDE_SHADOWING 1
#define AU_DIRECTIONAL_SHADING 1
#define AU_BLOCKLIGHT_STRENGTH 1.0
#define AU_BLOCKLIGHT_RANGE 1.75       // Hytale glow -> Minecraft lightmap scale
#define AU_BLOCKLIGHT_HYTALE_HUE 1.0 // 0 = warm torch light, 1 = Hytale's per-light colours
#define AU_EMISSION_STRENGTH 3.0
#define AU_EMISSIVE_MAX 1.6           // brightest a glowing ore texel gets (keeps its colour; the glow is bloom)
#define AU_EMISSIVE_BLOOM 4.0        // extra bloom for emissive blocks (flames, potions, lava)
#define AU_ORE_GLOW 1                 // ore specks glow (1), 2 = debug: every REFLECTIVE block glows
#define AU_ORE_GLOW_STRENGTH 2.0
#define AU_ORE_BLOOM 10.0             // coloured glow halo around ore crystals
#define AU_ORE_LIGHT 8.0              // light ore crystals cast on what is around them (RTX preset)
#define AU_ORE_SHINE 1.0
#define AU_ORE_SHINE_SPEED 0.18
#define AU_ORE_SHINE_WIDTH 0.12
#define AU_ORE_ANIMATION 1
#define AU_ORE_PULSE_STRENGTH 0.85
#define AU_ORE_PULSE_SPEED 0.5
#define AU_MATERIALS 1                // block materials: polished stone/bricks/planks/ice gloss, metal reflections, rain soaking
#define AU_MATERIAL_GLOSS 1.0
#define AU_RAIN_WETNESS 1.0           // how wet and glossy rain makes everything open to the sky
#define AU_RAIN_SOAKING 1.0
#define AU_ORE_GLOSS 1.0              // ore crystals glossy like gems (sun glints, reflections)
#define AU_SSAO_STRENGTH 1.25
#define AU_AO_METHOD 0
#define AU_GTAO_QUALITY 2
#define AU_GTAO_RADIUS 1.5
#define AU_GTAO_BENT_NORMALS 1
#define AU_CAVE_LIGHTING 250.0        // minimum light underground, %
#define AU_SUBSURFACE 1              // foliage translucency
#define AU_SUBSURFACE_GLOW 0.35
#define AU_SSS 1
#define AU_SSS_STRENGTH 0.65
#define AU_SSS_THICKNESS 1.0
#define AU_SSS_ABSORPTION 1.0
#define AU_SSS_VOXEL 1
#define AU_SSS_TEXTURES 1
#define AU_SSS_MASK_STRENGTH 1.0
#define AU_SSS_SHADOW_DITHER 0.5
#define AU_SSS_DENSITY 0.55
#define AU_SSS_TRACE_DISTANCE 12.0
#define AU_SSS_TRACE_STEPS 32
#define AU_GENERATED_NORMALS 1        // per-texel relief from block textures
#define AU_GENERATED_NORMAL_MULT 100.0  // relief strength (25-400)
#define AU_GENERATED_NORMAL_RES 128.0   // relief resolution (16-512)
#define AU_MATERIAL_RELIEF 1.0
#define AU_LIGHT_HIGHLIGHT 1         // soft GGX sun highlight

// ---- Shadows -------------------------------------------------------------------------
#define AU_SHADOW_SAMPLES 24
#define AU_SHADOW_SOFTNESS 1.0
#define AU_SHADOW_CASCADES 4
#define AU_PCSS 1                    // contact-hardening shadows (needs the hook's raw shadow share)
#define AU_PCSS_SEARCH 9.0           // max penumbra / blocker search radius in shadow texels
#define AU_PCSS_SCALE 900.0          // shadow-depth difference -> penumbra texels
#define AU_CONTACT_SHADOWS 1         // screen-space shadows for grass/plants (not in Hytale's shadow map)
#define AU_CONTACT_SHADOW_LENGTH 1.6
#define AU_CONTACT_SHADOW_STEPS 18
#define AU_CONTACT_SHADOW_DISTANCE 480.0
#define AU_FAR_SHADOWS 1              // screen-space shadows past the shadow map
#define AU_CLOTH_TRANSMIT 0.5         // sun through cloth and other two-sided models (a curtain shows the window behind it)
#define AU_FAR_SHADOW_STEPS 32
#define AU_NEAR_IGNORE 1.2             // depth (blocks) below which geometry is the first-person hand

// ---- Sky / atmosphere ----------------------------------------------------------------
#define AU_BIOME_ATMOSPHERE 0
#define AU_ATMOSPHERE_MODEL 0
#define AU_STARS 2                    // 0 off, 1 procedural, 2 Hytale's star texture (turning with the sky)
#define AU_STARS_BRIGHTNESS 2.0
#define AU_MOON_GLOW 1.0              // Hytale's halo around the moon
#define AU_AURORA 0
#define AU_AURORA_STYLE 2
#define AU_AURORA_STRENGTH 1.0
#define AU_AURORA_SPEED 1.0
#define AU_STARS_SCALE 1.0             // star texture size on the sky (lower = bigger stars)
#define AU_NIGHT_SKY_SATURATION 3.0   // night horizon colour (1 = grey-blue, higher = deep blue)
#define AU_ATMOSPHERIC_FOG 1
#define AU_ATM_FOG_MULT 0.95
#define AU_ATM_FOG_DISTANCE 1.0
#define AU_MIST 0
#define AU_MIST_DENSITY 1.0
#define AU_MIST_ALTITUDE 118.0
#define AU_MIST_HEIGHT 6.0
#define AU_MIST_NOON 0.15
#define AU_MIST_DISTANCE 160.0
#define AU_MIST_SAMPLES 12
#define AU_BORDER_FOG 1
#define AU_CAVE_ALTITUDE 95.0        // below this height with no sky light around = cave (cave fog)
#define AU_RAINBOWS 1                // rainbow opposite the sun after rain (morning / evening)
#define AU_RAINBOW_DIAMETER 1.0
#define AU_HYTALE_SKY_TINT 0.15      // how much Hytale's biome/weather sky colour bleeds into the palette

// ---- Clouds (Unbound style volumetric) -----------------------------------------------
#define AU_CLOUDS 1
#define AU_CLOUD_ALT1 300.0          // world height of the first cloud layer
#define AU_CLOUD_ALT2 340.0          // second layer (set AU_CLOUD_LAYERS 1 to disable)
#define AU_CLOUD_LAYERS 2
#define AU_CLOUD_LIGHTING 0
#define AU_CLOUD_LIGHT_SAMPLES 1
#define AU_CLOUD_AMOUNT 1.0
#define AU_CLOUD_SPEED 1.0
#define AU_CLOUD_STEP 14.0
#define AU_CLOUD_DISTANCE 2400.0
#define AU_CLOUD_SHADOWS 1
#define AU_CLOUD_SHADOW_STRENGTH 1.0

// ---- Volumetric light ----------------------------------------------------------------
#define AU_LIGHTSHAFTS 1
#define AU_LIGHTSHAFT_SAMPLES 28
#define AU_LIGHTSHAFT_STRENGTH 1.0
#define AU_LIGHTSHAFT_HAZE 0.4         // open-air haze (beams through trees / windows are separate)
#define AU_LIGHTSHAFT_DISTANCE 192.0
#define AU_LIGHTSHAFT_SCENE_AWARE 1.0  // stronger shafts in caves / forests (0 = off)
#define AU_LIGHTSHAFT_NOON_I 1.0
#define AU_LIGHTSHAFT_SUNSET_I 0.5    // low-sun haze (the low sun's light colour is strong; 1.0 drowned the land)
#define AU_LIGHTSHAFT_NIGHT_I 0.35     // moonlight haze (1.0 washes Hytale nights out)
#define AU_LIGHTSHAFT_SCENE_BOOST 1.0  // extra shaft strength under canopies / in caves (0 = off)
#define AU_LIGHT_FOG 0
#define AU_LIGHT_FOG_DENSITY 1.0
#define AU_LIGHT_FOG_DISTANCE 24.0
#define AU_LIGHT_FOG_SAMPLES 6

// ---- Water ---------------------------------------------------------------------------
#define AU_WATER 1
#define AU_GLASS 1                    // glass tints and reflects what is behind it
#define AU_GLASS_TINT 0.7
#define AU_GLASS_ABSORB 0.35            // how much light glass takes away from the view through it
#define AU_GLASS_REFLECT 0.8
#define AU_WATER_FOG_MULT 1.0
#define AU_WATER_MODEL 0
#define AU_WATER_CLARITY 1.0
#define AU_WATER_SSR_STEPS 48
#define AU_WATER_REFRACTION 2.0       // refraction strength
#define AU_WATER_FOAM 0.5              // shoreline foam
#define AU_WATER_CAUSTICS 1          // Unbound caustics on sunlit surfaces while the camera is under water
#define AU_CAUSTICS_STRENGTH 1.4
#define AU_DEBUG_WATER 0

// ---- Rain puddles ---------------------------------------------------------------------
#define AU_RAIN_PUDDLES 1             // reflective puddles while wet
#define AU_RAIN_PUDDLE_STRENGTH 1.0

// ---- RTX preset ----------------------------------------------------------------------
#define AU_HALF_RES_FX 0              // hook: screen-space GI and light shafts at half resolution, upsampled by depth
#define AU_HALF_HISTORY 16            // hook: frames the half-resolution GI accumulates (its denoiser; 1 = off)
#define AU_RTX_GI_RAYS 8
#define AU_RTX_GI_RADIUS 8.0
#define AU_RTX_GI_STRENGTH 1.0
#define AU_RTX_GI_EMISSIVE 1.0       // bounce from emissive blocks (torch flames, lava)
#define AU_RTX_AO_RADIUS 2.5        // reach (blocks) of the ray-traced AO
#define AU_RTX_GI_AO 0.55          // how much the GI rays darken occluded ambient
#define AU_RTX_SSR_STEPS 32
#define AU_SSR_REFINED 1
#define AU_RTX_SMOOTHNESS 0.0          // dry surfaces stay matte (only rain makes them reflective)
#define AU_SSGI_DENOISE 1
#define AU_GI_DENOISER 1
#define AU_GI_HISTORY_TAPS 9
#define AU_GI_SPATIAL_STRENGTH 1.0
#define AU_GI_NORMAL_THRESHOLD 0.05
#define AU_GI_PLANE_TOLERANCE 0.03
#define AU_GI_HISTORY_REACH 0.3
#define AU_GI_MAX_HISTORY 0.92
#define AU_GI_LIGHT_REJECTION 0.25
#define AU_PT_DENOISE 1
#define AU_GI_SPATIAL_FILTER 1
#define AU_GI_TEMPORAL_FILTER 1
#define AU_SSGI_HISTORY 8.0
#define AU_SSGI_SELF_HIT_FIX 1
#define AU_GI_DENOISE ((AU_PRESET >= 2 || AU_LOCAL_LIGHTS) && AU_GI_DENOISER > 0 && (AU_GI_SPATIAL_FILTER || AU_GI_TEMPORAL_FILTER) && ((AU_VOXELS && AU_PT_DENOISE) || (!AU_VOXELS && AU_SSGI_DENOISE)))
#define AU_GI_LEGACY AU_GI_DENOISE
#define AU_NATIVE_EMISSION 1
#define AU_NATIVE_EMISSION_STRENGTH 1.0
#define AU_LOCAL_LIGHTS 1
#define AU_LOCAL_LIGHT_RANGE 8.0
#define AU_LOCAL_LIGHT_STRENGTH 1.0
#define AU_EMISSIVE_LIGHT_STRENGTH 1.75
#define AU_LOCAL_LIGHT_COLOR_BLEND 1.0
#define AU_LIGHT_CACHE_SECONDS 1.0
#define AU_LOCAL_LIGHT_SOFTNESS 0.35
#define AU_LOCAL_LIGHT_CANDIDATES 8
#define AU_LOCAL_LIGHT_BUDGET 32       // most area lights evaluated per pixel; more reaching a spot are sampled
#define AU_ORE_TORCH_RATIO 0.3
#define AU_DYNAMIC_SHADOWS 1          // torches in hand, lanterns and other moving lights cast shadows (LightClusteredFS)
#define AU_DYNAMIC_LIGHT_FACING 0.8   // how much those lights follow the way a surface faces them (0 = Hytale's flat light)
#define AU_DYNAMIC_LIGHT_SIZE 0.6     // size of those lights: softer shadows when larger
#define AU_VOXEL_WORLD (AU_VOXELS || AU_LOCAL_LIGHTS || (AU_SSS && AU_SSS_VOXEL == 1) || AU_DYNAMIC_SHADOWS)
#define AU_VOXEL_ATLAS 0              // hook (macOS): the grid in 2D textures the hook writes, for OpenGL without image load/store

// ---- Path tracing (RTX preset) -------------------------------------------------------
// Voxel path tracing: the hook keeps a 256x128x256 block grid of the world around the
// player (include/AU_Voxel.glsl) and the bounce light traces rays through it.
#define AU_PATH_TRACING 0             // experimental: heavy, and the look is close to the screen-space GI
#define AU_PT_GI_STRENGTH 1.5         // bounce light strength with path tracing
#define AU_VOXELS (AU_PRESET >= 2 && AU_PATH_TRACING)
#define AU_PT_RAYS 3                  // rays per pixel per frame
#define AU_PT_REACH 24.0              // how far (blocks) rays travel
#define AU_PT_HISTORY 24.0            // frames the path tracer averages over (more = smoother, slower to react)
#define AU_PT_SKY_LIGHT 0.8           // how much the traced sky visibility shapes the ambient light
#define AU_PT_LIGHTS (0)
#define AU_PT_AMBIENT_BOUNCE 1.0      // how much sky light bounced surfaces pass on (multiple bounces)
#define AU_VOXEL_DEBUG 0              // 1 = show the voxel grid (ray cast from the camera), 2 = blend over the scene

// ---- Post ----------------------------------------------------------------------------
#define AU_TM_EXPOSURE 1.00
#define AU_TM_CONTRAST 1.10
#define AU_TM_WHITE_PATH 1.00
#define AU_TM_DARK_DESATURATION 0.25
#define AU_TM_HIGHLIGHT_PROTECT 0.0
#define AU_WB_TEMPERATURE 0.0
#define AU_WB_TINT 0.0
#define AU_ADAPTIVE_EXPOSURE 0
#define AU_ADAPT_STRENGTH 0.6
#define AU_SATURATION 1.00
#define AU_VIBRANCE 1.00
#define AU_BLOOM 1
#define AU_BLOOM_STRENGTH 0.12
#define AU_BLOOM_FOG 1                // glowing haze at night, in rain, caves and underwater
#define AU_KEEP_HYTALE_GRADING 0.6   // how much of Hytale's per-biome colour filter/saturation to keep
#define AU_VIGNETTE 1
#define AU_LENSFLARE 1                // lens flare (sun and moon)
#define AU_LENSFLARE_I 2.5             // lens flare strength
#define AU_SUN_GLARE 1.0              // soft lens glare around the visible sun
#define AU_TAA 1                      // reprojected TAA (cleans up dithered shafts / shadows / GI)
#define AU_DLSS 0                     // NVIDIA DLSS instead of the TAA (hook/aud_dlss.c; RTX GPUs)
#define AU_RENDER_SCALE 0
#define AU_METALFX 0                  // macOS: Apple MetalFX temporal upscaling instead of the TAA (hook/aud_metalfx.m)
#define AU_METALFX_DENOISER 0         // macOS 26+: MetalFX's denoised scaler (its Ray Reconstruction)
#define AU_METALFX_METAL4 1           // macOS 26+: submit MetalFX through Metal 4 (the original queue lets the GPU clock drop)
#define AU_METALFX_PIPELINE 1        // macOS: show MetalFX's output one frame later instead of waiting for the GPU every frame
#define AU_MAC_SETTINGS 2             // installer: macOS settings migrations applied (tools/linux_hook.py)
#define AU_DLSS_PRESET 0              // hook: DLSS model, 0 NVIDIA's default, 1 sharpest (K / RR E), 2 less ghosting (J / RR D)
#define AU_DLSS_RR_PRESET 0
#define AU_DLSS_SHARPNESS 0.2
#define AU_DLSS_FRAMEGEN 0
#define AU_DLSS_JITTER 1              // hook: sub-pixel camera jitter while DLSS runs
#define AU_DLSS_JITTER_SX 1           // hook: sign of the jitter handed to DLSS (axis conventions)
#define AU_DLSS_JITTER_SY 1
#define AU_DLSS_MOTION_SX 1           // hook: sign of the motion vectors handed to DLSS
#define AU_DLSS_MOTION_SY 1
#define AU_DLSS_DEBUG 0               // hook: 1 = show DLSS's colour input, 2 = reset every frame, 3 = depth, 4 = motion
#define AU_DLSS_DEPTH_HW 0            // hand DLSS hardware-style (non-linear) depth instead of linear
#define AU_TAA_BLEND 0.93             // history weight (higher = smoother, softer motion)
#define AU_TAA_CLIP 1.25              // neighbourhood variance clip (lower = less ghosting)
#define AU_TAA_JITTER 0               // hook: sub-pixel camera jitter for the TAA when no upscaler runs
#define AU_UPSCALE_SHARPNESS 0.3      // hook: sharpening of the bicubic scale-to-window (Hytale Render Scale < 100)
#define AU_SHARPENING 2               // image sharpening (0-10)

#define AU_DEBUG_CLASS 0
#define AU_DEBUG_TAA 0
//#define AU_DEBUG_FAKE_SUN 0.9     // debug: force a sun elevation (sin)
#define AU_DEBUG 0                   // on-screen value bars (top-left)

#endif
