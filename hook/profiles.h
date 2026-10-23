#include <errno.h>

#define AU_USER_PROFILES 16
#define AU_BUILTIN_PROFILES 12
#define AU_DEFAULT_PROFILE (-2)

static int g_menuProfileDelete = -1;
static double g_menuProfileDeleteArmedAt, g_menuProfileDeleteUntil;
static uint64_t g_menuProfileDeleteHash;

static MenuOpt *menu_profile_find(int selected)
{
    for (int index = 0; index < g_nMo; index++)
        if (g_mo[index].kind == MO_PROFILE && (int)g_mo[index].value == selected) return &g_mo[index];
    return NULL;
}

static void menu_profile_row(int tab, int kind, int selected, const wchar_t *label, const wchar_t *help)
{
    if (g_nMo >= MENU_MAX) return;
    MenuOpt *entry = &g_mo[g_nMo++];
    memset(entry, 0, sizeof(*entry));
    entry->tab = tab;
    entry->kind = kind;
    entry->value = selected;
    entry->def = -1;
    entry->present = 1;
    snprintf(entry->define, sizeof(entry->define), "!PROFILE_%s_%d", kind == MO_SECTION ? "GROUP" : "SELECT", selected);
    wcsncpy(entry->label, label, 63);
    wcsncpy(entry->help, help, 191);
    g_menuTabs[tab].count++;
}

static void menu_profiles_load(MenuOpt *option)
{
    static const wchar_t *names[] = {L"Lowest", L"Low", L"Medium", L"High", L"Highest", L"Ultra"};
    int tab = option->tab;
    g_menuTabs[tab].count--;
    menu_profile_row(tab, MO_PROFILE, AU_DEFAULT_PROFILE, L"Default",
        L"Restores the saved original defaults. This baseline is separate from the quality presets. Click or press Right to apply.");
    for (int family = 0; family < 2; family++) {
        menu_profile_row(tab, MO_SECTION, family, family == 0 ? L"RTX presets" : L"Non-RTX presets", L"");
        for (int tier = 0; tier < 6; tier++)
            menu_profile_row(tab, MO_PROFILE, family * 6 + tier, names[tier], family == 0
                ? L"GI and material reflections. DLSS Quality+ at 77% with NVIDIA RR when supported; Original fallback otherwise. Path tracing stays off. Click or press Right to apply."
                : L"Lighter lighting without bounce GI or material SSR. Original denoiser; DLSS off, native resolution. No path tracing. Click or press Right to apply.");
    }
    menu_profile_row(tab, MO_SECTION, 2, L"Saved profiles", L"");
    for (int slot = 0; slot < AU_USER_PROFILES; slot++) {
        char relative[64];
        snprintf(relative, sizeof relative, "presets/preset-%02d.glsl", slot);
        char *saved = read_file(relative, NULL);
        if (!saved) continue;
        if (!strncmp(saved, "// Aurora preset: ", 18)) {
            char *name = saved + 18;
            name[strcspn(name, "\r\n")] = 0;
            if (*name) {
                wchar_t label[64];
                to_wide(label, 64, name);
                menu_profile_row(tab, MO_PROFILE, slot + AU_BUILTIN_PROFILES, label,
                    L"Restores your saved shader settings, including any manually selected DLSS configuration. Click or press Right to apply.");
            }
        }
        free(saved);
    }
    if (!menu_profile_find(g_menuProfileChoice)) g_menuProfileChoice = -1;
}

static void menu_profile_set(const char *name, double value)
{
    for (int index = 0; index < g_nMo; index++)
        if (!strcmp(g_mo[index].define, name) && g_mo[index].present) g_mo[index].value = value;
}

#ifdef __APPLE__
#include <sys/sysctl.h>
// GPU class of this Mac, as tools/linux_hook.py mac_tier: 2 for M4 Pro / Max, M5 and later, 1 for
// the Pro and Max chips before them and M3 / M4, 0 for M1 / M2.
static int apple_gpu_tier(void)
{
    char brand[128] = "";
    size_t size = sizeof brand;
    int generation = 0;
    char variant[16] = "";
    if (sysctlbyname("machdep.cpu.brand_string", brand, &size, NULL, 0) || sscanf(brand, "Apple M%d %15s", &generation, variant) < 1)
        return 1;
    if (generation >= 5 || (generation >= 4 && variant[0])) return 2;
    return variant[0] || generation >= 3 ? 1 : 0;
}
#endif

static void menu_profile_builtin(int selected)
{
    static const struct {
        int shadowSamples, shaftSamples, giRays, reflectionSteps, waterSteps, contactSteps, farSteps, scatterSteps;
        double cloudStep, contactDistance;
    } quality[] = {
        {4, 4, 4, 8, 8, 6, 8, 16, 64.0, 48.0},
        {8, 8, 4, 12, 12, 8, 12, 16, 48.0, 72.0},
        {12, 12, 8, 16, 16, 12, 16, 16, 32.0, 128.0},
        {24, 20, 8, 32, 24, 18, 24, 24, 20.0, 256.0},
        {32, 28, 12, 48, 40, 24, 32, 32, 14.0, 384.0},
        {48, 40, 16, 64, 64, 32, 48, 48, 8.0, 480.0}
    };
    static const double reach[] = {4.0, 4.0, 6.0, 8.0, 12.0, 16.0};
    int tier = selected % 6;
    int rtx = selected < 6;
    for (int index = 0; index < g_nMo; index++) {
        MenuOpt *entry = &g_mo[index];
        if (entry->present && !strncmp(entry->define, "AU_", 3) && strcmp(entry->define, "AU_MENU_KEY")) entry->value = entry->def;
    }
    menu_profile_set("AU_PRESET", rtx ? 2 : 1);
    menu_profile_set("AU_DLSS", rtx && AU_HAS_DLSS);
    menu_profile_set("AU_GI_DENOISER", rtx && AU_HAS_DLSS ? 2 : 1);
    menu_profile_set("AU_RENDER_SCALE", rtx && AU_HAS_DLSS ? 77 : 100);
    menu_profile_set("AU_DLSS_FRAMEGEN", 0);
    menu_profile_set("AU_PATH_TRACING", 0);
    menu_profile_set("AU_POLISH_SUNLIGHT", tier >= 2);
    menu_profile_set("AU_SHADOW_SAMPLES", quality[tier].shadowSamples);
    menu_profile_set("AU_PCSS", rtx && tier >= 2);
    menu_profile_set("AU_CONTACT_SHADOWS", tier >= 1);
    menu_profile_set("AU_CONTACT_SHADOW_STEPS", quality[tier].contactSteps);
    menu_profile_set("AU_CONTACT_SHADOW_DISTANCE", quality[tier].contactDistance);
    menu_profile_set("AU_FAR_SHADOWS", tier >= 2);
    menu_profile_set("AU_FAR_SHADOW_STEPS", quality[tier].farSteps);
    menu_profile_set("AU_CLOUDS", tier >= 1);
    menu_profile_set("AU_CLOUD_STEP", quality[tier].cloudStep);
    menu_profile_set("AU_CLOUD_LAYERS", tier >= 3 ? 2 : 1);
    menu_profile_set("AU_CLOUD_SHADOWS", tier >= 2);
    menu_profile_set("AU_LIGHTSHAFTS", tier >= 1);
    menu_profile_set("AU_LIGHTSHAFT_SAMPLES", quality[tier].shaftSamples);
    menu_profile_set("AU_LOCAL_LIGHTS", tier == 5);
    menu_profile_set("AU_SSS", tier >= 1);
    menu_profile_set("AU_SSS_VOXEL", tier >= 3 ? 1 : 0);
    menu_profile_set("AU_SSS_TRACE_STEPS", quality[tier].scatterSteps);
    menu_profile_set("AU_GENERATED_NORMALS", tier >= 2);
    menu_profile_set("AU_MATERIALS", tier >= 2);
    menu_profile_set("AU_LIGHT_HIGHLIGHT", tier >= 1);
    menu_profile_set("AU_RTX_GI_RAYS", quality[tier].giRays);
    menu_profile_set("AU_RTX_GI_RADIUS", reach[tier]);
    menu_profile_set("AU_RTX_SSR_STEPS", quality[tier].reflectionSteps);
    menu_profile_set("AU_WATER", tier >= 1);
    menu_profile_set("AU_WATER_SSR_STEPS", quality[tier].waterSteps);
    menu_profile_set("AU_WATER_CAUSTICS", tier >= 2);
    menu_profile_set("AU_GLASS", tier >= 1);
    menu_profile_set("AU_RAIN_PUDDLES", tier >= 2);
    // Visual upgrade (docs/surfaces-and-water.md, docs/clouds-and-sky.md), by measured cost:
    // sky light (per draw, not per pixel), enhanced water and atmosphere from Medium; GTAO (about
    // 0.3 ms at its medium quality) from High; detailed cloud lighting from Highest. Ground mist
    // (its altitude depends on the world) and the aurora (a taste) stay user choices.
    menu_profile_set("AU_SKY_LIGHTING", tier >= 2);
    menu_profile_set("AU_WATER_MODEL", tier >= 2);
    menu_profile_set("AU_ATMOSPHERE_MODEL", tier >= 2);
    menu_profile_set("AU_AO_METHOD", tier >= 3);
    menu_profile_set("AU_GTAO_QUALITY", tier >= 5 ? 3 : tier == 4 ? 2 : 1);
    menu_profile_set("AU_CLOUD_LIGHTING", tier >= 4);
#ifdef __APPLE__
    // Apple Silicon at Retina sizes: MetalFX renders below the window size (less for the non-RTX
    // profiles and on faster chips), the TAA jitters, the screen-space GI and light shafts run at half resolution, and the
    // per-pixel sample counts the temporal filters integrate anyway stay moderate. The denoised
    // scaler stays a manual choice: it costs several times the upscale at these sizes.
    menu_profile_set("AU_TAA_JITTER", 1);
    menu_profile_set("AU_HALF_RES_FX", 1);
    // Render size by GPU class: an M1 Pro runs the same profiles at 58 percent, an M1 at 50.
    // (Values of the menu's Render resolution list.)
    static const int renderScale[2][3] = {{58, 67, 77}, {50, 58, 67}};
    menu_profile_set("AU_METALFX", 1);
    menu_profile_set("AU_RENDER_SCALE", renderScale[rtx][apple_gpu_tier()]);
    menu_profile_set("AU_RTX_GI_RAYS", quality[tier].giRays < 4 ? quality[tier].giRays : 4);
    menu_profile_set("AU_LIGHTSHAFT_SAMPLES", quality[tier].shaftSamples < 16 ? quality[tier].shaftSamples : 16);
    menu_profile_set("AU_SHADOW_SAMPLES", quality[tier].shadowSamples < 16 ? quality[tier].shadowSamples : 16);
    menu_profile_set("AU_FAR_SHADOW_STEPS", quality[tier].farSteps < 24 ? quality[tier].farSteps : 24);
#endif
}

static void menu_profile_apply(void)
{
    g_menuProfileDelete = -1;
    int selected = g_menuProfileChoice;
    MenuOpt *profile = menu_profile_find(selected);
    if (!profile) return;
    char *saved = NULL;
    if (selected == AU_DEFAULT_PROFILE || selected >= AU_BUILTIN_PROFILES) {
        char relative[64];
        if (selected == AU_DEFAULT_PROFILE) snprintf(relative, sizeof relative, "presets/default.glsl");
        else snprintf(relative, sizeof relative, "presets/preset-%02d.glsl", selected - AU_BUILTIN_PROFILES);
        saved = read_file(relative, NULL);
        if (!saved) {
            _snwprintf(g_menuStatus, 96, L"The selected profile is missing");
            return;
        }
    }
    if (!saved) menu_profile_builtin(selected);
    for (int index = 0; saved && index < g_nMo; index++) {
        MenuOpt *option = &g_mo[index];
        if (!option->present || strncmp(option->define, "AU_", 3) || !strcmp(option->define, "AU_MENU_KEY")) continue;
        char *end = NULL;
        char *token = find_define_value(saved, option->define, &end);
        if (!token) {
            if (!strncmp(option->define, "AU_POLISH_", 10)) option->value = option->def;
            continue;
        }
        char *parsed = NULL;
        double value = strtod(token, &parsed);
        if (parsed != end || !isfinite(value)) continue;
        if (option->kind == MO_BOOL) value = value >= 0.5;
        else if (option->kind == MO_INTERNAL && !strcmp(option->define, "AU_PRESET") && value != 1.0 && value != 2.0) continue;
        else if (option->kind == MO_RANGE) value = fmin(option->max, fmax(option->min, value));
        else if (option->kind == MO_ENUM) {
            int valid = 0;
            for (int entry = 0; entry < option->nEnum; entry++)
                if (fabs(option->enumVal[entry] - value) < 1e-9) valid = 1;
            if (!valid) continue;
        }
        option->value = value;
    }
    free(saved);
#if !AU_HAS_DLSS
    menu_profile_set("AU_DLSS", 0);
    menu_profile_set("AU_GI_DENOISER", 1);
#ifndef __APPLE__
    menu_profile_set("AU_RENDER_SCALE", 100);   // MetalFX uses it on macOS
#endif
#endif
    g_toggleOff = 0;
    g_menuWriteAt = 0;
    menu_save();
    InterlockedExchange(&g_reloadRequested, 1);
    _snwprintf(g_menuStatus, 96, L"%ls%ls applied", selected >= 0 && selected < 6 ? L"RTX " : selected >= 6 && selected < AU_BUILTIN_PROFILES ? L"Non-RTX " : L"", profile->label);
    g_menuDirty = 1;
}

static void menu_profile_finish(void)
{
    g_menuProfileDelete = -1;
    wchar_t name[64];
    wcsncpy(name, g_menuSearch, 63);
    name[63] = 0;
    size_t length = wcslen(name);
    while (length && iswspace(name[length - 1])) name[--length] = 0;
    wchar_t *start = name;
    while (iswspace(*start)) start++;
    if (!*start) {
        _snwprintf(g_menuStatus, 96, L"Enter a preset name first");
        return;
    }
    for (int index = 0; index < g_nMo; index++)
        if (g_mo[index].kind == MO_PROFILE && !wcscmp(start, g_mo[index].label)) {
            _snwprintf(g_menuStatus, 96, L"Name already exists; choose another name");
            return;
        }
    int slot = -1;
    char relative[64];
    for (int index = 0; index < AU_USER_PROFILES; index++) {
        snprintf(relative, sizeof relative, "presets/preset-%02d.glsl", index);
        char *existing = read_file(relative, NULL);
        if (!existing) { slot = index; break; }
        free(existing);
    }
    if (slot < 0) {
        _snwprintf(g_menuStatus, 96, L"All 16 custom preset slots are used");
        return;
    }
    menu_save();
    char *settings = read_file(MENU_SETTINGS, NULL);
    if (!settings) return;
    char encoded[256];
#ifdef _WIN32
    if (!WideCharToMultiByte(CP_UTF8, 0, start, -1, encoded, sizeof encoded, NULL, NULL)) { free(settings); return; }
#else
    au_to_utf8(encoded, sizeof encoded, start);
#endif
    wchar_t directory[MAX_PATH], pending[MAX_PATH], destination[MAX_PATH];
    pack_path(directory, "presets");
    CreateDirectoryW(directory, NULL);
    pack_path(pending, "presets/pending.tmp");
    pack_path(destination, relative);
    FILE *output = _wfopen(pending, L"wb");
    int complete = 0;
    if (output) {
        int wrote = fprintf(output, "// Aurora preset: %s\n%s", encoded, settings);
        int closed = fclose(output);
        if (wrote > 0 && closed == 0) {
#ifdef _WIN32
            complete = MoveFileW(pending, destination) != 0;
#else
            char sourcePath[MAX_PATH], destinationPath[MAX_PATH];
            au_to_utf8(sourcePath, sizeof sourcePath, pending);
            au_to_utf8(destinationPath, sizeof destinationPath, destination);
            complete = rename(sourcePath, destinationPath) == 0;
#endif
        }
    }
    free(settings);
    if (!complete) {
        DeleteFileW(pending);
        _snwprintf(g_menuStatus, 96, L"Could not save preset; check folder permissions");
        return;
    }
    g_menuProfileChoice = slot + AU_BUILTIN_PROFILES;
    g_menuPresetNaming = 0;
    g_menuSearchFocus = 0;
    g_menuSearch[0] = 0;
    menu_load();
    _snwprintf(g_menuStatus, 96, L"Preset saved");
    g_menuDirty = 1;
}

static MenuOpt *menu_profile_custom(void)
{
    if (g_menuProfileChoice < AU_BUILTIN_PROFILES || g_menuProfileChoice >= AU_BUILTIN_PROFILES + AU_USER_PROFILES) return NULL;
    return menu_profile_find(g_menuProfileChoice);
}

static int menu_profile_delete_armed(void)
{
    return menu_profile_custom() && g_menuProfileDelete == g_menuProfileChoice && now_sec() < g_menuProfileDeleteUntil;
}

static void menu_profile_disarm_delete(void)
{
    g_menuProfileDelete = -1;
}

static void menu_profile_action_display(const char *name, wchar_t *out, int cap)
{
    MenuOpt *profile = menu_profile_custom();
    if (!profile) _snwprintf(out, cap, L"%ls saved profile", !strcmp(name, "!PROFILE_EXPORT") ? L"Export" : L"Delete");
    else _snwprintf(out, cap, L"%ls: %ls", !strcmp(name, "!PROFILE_EXPORT") ? L"Export"
                   : menu_profile_delete_armed() ? L"Confirm delete" : L"Delete", profile->label);
    out[cap - 1] = 0;
}

static int menu_profile_export_file(const MenuOpt *profile, const char *saved, size_t length, char *relative, size_t capacity)
{
    char slug[33];
    size_t used = 0;
    for (int index = 0; profile->label[index] && used < sizeof(slug) - 1; index++) {
        wchar_t character = profile->label[index];
        if ((character >= L'a' && character <= L'z') || (character >= L'A' && character <= L'Z') || (character >= L'0' && character <= L'9'))
            slug[used++] = (char)character;
        else if (used && slug[used - 1] != '-') slug[used++] = '-';
    }
    while (used && slug[used - 1] == '-') used--;
    slug[used] = 0;
    if (!used) strcpy(slug, "profile");
    wchar_t directory[MAX_PATH];
    pack_path(directory, "presets/exports");
    CreateDirectoryW(directory, NULL);
    for (int copy = 1; copy <= 999; copy++) {
        int count = snprintf(relative, capacity, "presets/exports/Aurora-%s-%02d-%03d.glsl", slug, (int)profile->value - AU_BUILTIN_PROFILES, copy);
        if (count < 0 || (size_t)count >= capacity || wcslen(g_packDir) + strlen(relative) + 2 > MAX_PATH) return 0;
        wchar_t destination[MAX_PATH];
        pack_path(destination, relative);
        FILE *output = _wfopen(destination, L"wbx");
        if (!output) {
            if (errno == EEXIST) continue;
            return 0;
        }
        size_t wrote = fwrite(saved, 1, length, output);
        int closed = fclose(output);
        if (wrote == length && closed == 0) return 1;
        DeleteFileW(destination);
        return 0;
    }
    return 0;
}

static void menu_profile_export(void)
{
    g_menuProfileDelete = -1;
    MenuOpt *profile = menu_profile_custom();
    if (!profile) {
        _snwprintf(g_menuStatus, 96, L"Apply a saved custom profile to export it");
        g_menuDirty = 1;
        return;
    }
    char relative[128];
    snprintf(relative, sizeof relative, "presets/preset-%02d.glsl", (int)profile->value - AU_BUILTIN_PROFILES);
    size_t length = 0;
    char *saved = read_file(relative, &length);
    if (!saved || !menu_profile_export_file(profile, saved, length, relative, sizeof relative)) {
        _snwprintf(g_menuStatus, 96, L"Export failed; check profile and folder permissions");
    } else {
        _snwprintf(g_menuStatus, 96, L"Exported to shaderpack/presets/exports");
        logf_("menu: exported profile to %s", relative);
    }
    free(saved);
    g_menuDirty = 1;
}

static void menu_profile_delete(void)
{
    MenuOpt *profile = menu_profile_custom();
    if (!profile) {
        g_menuProfileDelete = -1;
        _snwprintf(g_menuStatus, 96, L"Only saved custom profiles can be deleted");
        g_menuDirty = 1;
        return;
    }
    char relative[64];
    snprintf(relative, sizeof relative, "presets/preset-%02d.glsl", (int)profile->value - AU_BUILTIN_PROFILES);
    size_t length = 0;
    char *saved = read_file(relative, &length);
    if (!saved) {
        g_menuProfileDelete = -1;
        _snwprintf(g_menuStatus, 96, L"The selected profile is missing");
        g_menuDirty = 1;
        return;
    }
    uint64_t hash = fnv1a(saved, length);
    free(saved);
    double time = now_sec();
    if (!menu_profile_delete_armed() || hash != g_menuProfileDeleteHash) {
        g_menuProfileDelete = g_menuProfileChoice;
        g_menuProfileDeleteHash = hash;
        g_menuProfileDeleteArmedAt = time;
        g_menuProfileDeleteUntil = time + 5.0;
        _snwprintf(g_menuStatus, 96, L"Confirm deletion: %ls", profile->label);
        g_menuStatus[95] = 0;
        g_menuDirty = 1;
        return;
    }
    if (time - g_menuProfileDeleteArmedAt < 0.5) return;
    wchar_t path[MAX_PATH];
    pack_path(path, relative);
    DeleteFileW(path);
    g_menuProfileDelete = -1;
    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) {
        _snwprintf(g_menuStatus, 96, L"Could not delete profile; check folder permissions");
    } else {
        g_menuProfileChoice = -1;
        menu_load();
        _snwprintf(g_menuStatus, 96, L"Profile deleted; current shader settings kept");
        logf_("menu: deleted custom profile %s", relative);
    }
    g_menuDirty = 1;
}

static void menu_profile_action(const char *name)
{
    if (!strcmp(name, "!PROFILE_APPLY")) menu_profile_apply();
    else if (!strcmp(name, "!PROFILE_EXPORT")) menu_profile_export();
    else if (!strcmp(name, "!PROFILE_DELETE")) menu_profile_delete();
    else if (!strcmp(name, "!PROFILE_SAVE")) {
        g_menuProfileDelete = -1;
        if (g_menuPresetNaming) menu_profile_finish();
        else {
            g_menuPresetNaming = 1;
            g_menuSearchFocus = 1;
            g_menuSearch[0] = 0;
            _snwprintf(g_menuStatus, 96, L"Type a name; Enter or Save name confirms");
            g_menuDirty = 1;
        }
    }
}

static void menu_profile_cancel(void)
{
    g_menuProfileDelete = -1;
    if (!g_menuPresetNaming) return;
    g_menuPresetNaming = 0;
    g_menuSearchFocus = 0;
    g_menuSearch[0] = 0;
    menu_rebuild_rows();
    g_menuDirty = 1;
}
