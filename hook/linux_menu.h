// SDL3 ABI event storage (SDL_events.h); keep SDL itself a runtime dependency.
typedef union { uint32_t type; uint64_t alignment; unsigned char bytes[128]; } LinuxMenuEvent;
static bool (*lm_poll)(LinuxMenuEvent *);
static int (*lm_peep)(LinuxMenuEvent *, int, int, uint32_t, uint32_t);
static const bool *(*lm_keys)(int *);
static uint32_t (*lm_mouse)(float *, float *), (*lm_global)(float *, float *), (*lm_relative)(float *, float *);
static bool (*lm_set_relative)(void *, bool), (*lm_set_grab)(void *, bool);
static bool (*lm_get_relative)(void *), (*lm_get_grab)(void *);
static bool (*lm_cursor)(void), (*lm_show)(void), (*lm_hide)(void);
static bool (*lm_size)(void *, int *, int *), (*lm_pixels)(void *, int *, int *);
static void *(*lm_focus)(void);
static uint32_t (*lm_id)(void *);
static void (*lm_warp)(void *, float, float);
static void *lm_window, *lm_captured_window;
static bool lm_ready, lm_saved_relative, lm_saved_grab, lm_saved_cursor;
static float lm_scale_x = 1, lm_scale_y = 1, lm_saved_x, lm_saved_y, lm_global_x, lm_global_y, lm_wheel;
static uint32_t lm_buttons;
static __thread int lm_polling;
static __thread bool lm_empty_keys[512];

static void linux_menu_init(void)
{
    if (lm_ready) return;
    void *handle = linux_sdl_handle ? linux_sdl_handle : RTLD_NEXT;
#define LM_LOAD(field, name) *(void **)(&field) = linux_real_dlsym(handle, name)
    LM_LOAD(lm_poll, "SDL_PollEvent"); LM_LOAD(lm_peep, "SDL_PeepEvents");
    LM_LOAD(lm_keys, "SDL_GetKeyboardState"); LM_LOAD(lm_focus, "SDL_GetKeyboardFocus");
    LM_LOAD(lm_mouse, "SDL_GetMouseState"); LM_LOAD(lm_global, "SDL_GetGlobalMouseState");
    LM_LOAD(lm_relative, "SDL_GetRelativeMouseState");
    LM_LOAD(lm_set_relative, "SDL_SetWindowRelativeMouseMode"); LM_LOAD(lm_get_relative, "SDL_GetWindowRelativeMouseMode");
    LM_LOAD(lm_set_grab, "SDL_SetWindowMouseGrab"); LM_LOAD(lm_get_grab, "SDL_GetWindowMouseGrab");
    LM_LOAD(lm_cursor, "SDL_CursorVisible"); LM_LOAD(lm_show, "SDL_ShowCursor"); LM_LOAD(lm_hide, "SDL_HideCursor");
    LM_LOAD(lm_size, "SDL_GetWindowSize"); LM_LOAD(lm_pixels, "SDL_GetWindowSizeInPixels");
    LM_LOAD(lm_id, "SDL_GetWindowID"); LM_LOAD(lm_warp, "SDL_WarpMouseInWindow");
#undef LM_LOAD
    lm_ready = lm_poll && lm_peep && lm_keys && lm_focus && lm_mouse && lm_global && lm_relative
        && lm_set_relative && lm_get_relative && lm_set_grab && lm_get_grab && lm_cursor && lm_show
        && lm_hide && lm_size && lm_pixels && lm_id && lm_warp;
}

static void linux_menu_sync(void)
{
    if (!lm_ready) return;
    int count = 0;
    const bool *keys = lm_keys(&count);
    bool capture = g_menuOpen && lm_window && lm_focus() == lm_window && keys
        && (g_menuBinding || (count > 224 && keys[224]) || (count > 228 && keys[228]));
    if (lm_captured_window && (!capture || lm_captured_window != lm_window)) {
        void *window = lm_captured_window;
        lm_captured_window = NULL;
        lm_relative(NULL, NULL); // Discard editing motion before returning the camera.
        lm_set_relative(window, lm_saved_relative);
        lm_set_grab(window, lm_saved_grab);
        if (lm_saved_cursor) lm_show(); else lm_hide();
        g_menuDragging = -1;
        g_menuSearchFocus = 0;
        g_menuMouseMode = 0;
        g_menuDirty = 1;
        lm_wheel = 0;
    }
    if (!capture) return;
    int w, h, pw, ph;
    if (lm_size(lm_window, &w, &h) && lm_pixels(lm_window, &pw, &ph) && w > 0 && h > 0) {
        lm_scale_x = (float)pw / w;
        lm_scale_y = (float)ph / h;
    }
    if (lm_captured_window) return;
    lm_saved_relative = lm_get_relative(lm_window);
    lm_saved_grab = lm_get_grab(lm_window);
    lm_saved_cursor = lm_cursor();
    lm_mouse(&lm_saved_x, &lm_saved_y);
    lm_global(&lm_global_x, &lm_global_y);
    if (!lm_set_relative(lm_window, false)) return;
    if (!lm_set_grab(lm_window, false)) {
        lm_set_relative(lm_window, lm_saved_relative);
        return;
    }
    lm_captured_window = lm_window;
    g_menuSDLReady = 1; // Shared hit testing allows the cursor outside the panel.
    g_menuMouseMode = 1;
    g_menuDirty = 1;
    if (g_menuPointerX <= 0 || g_menuPointerY <= 0) {
        g_menuPointerX = g_menuLayout.x + g_menuLayout.width / 2;
        g_menuPointerY = g_menuLayout.y + g_menuLayout.title / 2;
    }
    lm_warp(lm_window, g_menuPointerX / lm_scale_x, g_menuPointerY / lm_scale_y);
    lm_show();
}

static uint32_t linux_menu_u32(const LinuxMenuEvent *event, int offset)
{
    uint32_t value; memcpy(&value, event->bytes + offset, sizeof value); return value;
}
static float linux_menu_float(const LinuxMenuEvent *event, int offset)
{
    float value; memcpy(&value, event->bytes + offset, sizeof value); return value;
}

#include "linux_render_scale.h"

static bool linux_menu_filter(LinuxMenuEvent *event)
{
    linux_menu_sync();
#if AU_HAS_UPSCALER
    linux_render_scale_event(event);
#endif
    bool capture = lm_captured_window != NULL;
    // Leave events for other SDL windows untouched.
    if (!lm_window || (event->type >= 0x300 && event->type <= 0x403
        && linux_menu_u32(event, 16) != lm_id(lm_window))) return true;
    if (g_menuBinding && event->type == 0x300) {
        int scan = (int)linux_menu_u32(event, 24);
        for (int key = 8; key < 256; key++)
            if (menu_hotkey_scan(key) == scan) { menu_bind_key_event(key); break; }
    }
    if (event->type == 0x300 && !g_menuPresetNaming && !g_menuSearchFocus
        && linux_menu_u32(event, 24) == (uint32_t)menu_hotkey_scan(g_menuHotkey)) return false;
    if (event->type >= 0x400 && event->type <= 0x403) {
        uint32_t button = (event->type == 0x401 || event->type == 0x402) && event->bytes[24] >= 1
            && event->bytes[24] <= 32 ? 1u << (event->bytes[24] - 1) : 0;
        bool swallowed = (lm_buttons & button) != 0;
        if (event->type == 0x402) lm_buttons &= ~button;
        if (!capture) return !swallowed;
        if (event->type == 0x401) lm_buttons |= button;
        if (event->type != 0x403) {
            g_menuPointerX = linux_menu_float(event, 28) * lm_scale_x;
            g_menuPointerY = linux_menu_float(event, 32) * lm_scale_y;
            // Apply the final drag position before releasing the slider.
            menu_pointer(event->type == 0x401 && event->bytes[24] == 1);
            if (event->type == 0x402 && event->bytes[24] == 1) g_menuDragging = -1;
        } else {
            float wheel = linux_menu_float(event, 28);
            if (linux_menu_u32(event, 32) == 1) wheel = -wheel;
            lm_wheel -= wheel * 3;
            int rows = (int)lm_wheel;
            if (rows) { menu_scroll(rows); lm_wheel -= rows; }
        }
        linux_menu_sync(); // A click on Close must restore capture immediately.
        return false;
    }
    // Releases still reach the game so keys held before editing cannot get stuck.
    if (capture && (event->type == 0x300 || event->type == 0x302 || event->type == 0x303)) return false;
    return true;
}

__declspec(dllexport) bool SDL_PollEvent(LinuxMenuEvent *event)
{
    linux_menu_init(); linux_menu_sync();
    if (!lm_poll) return false;
    if (!event) return lm_poll(NULL);
    for (;;) {
        lm_polling++;
        bool available = lm_poll(event);
        lm_polling--;
        if (!available) { linux_menu_sync(); return false; }
        if (!lm_ready || linux_menu_filter(event)) return true;
    }
}

__declspec(dllexport) int SDL_PeepEvents(LinuxMenuEvent *events, int capacity, int action, uint32_t minimum, uint32_t maximum)
{
    linux_menu_init();
    if (!lm_peep) return -1;
    if (!lm_polling) linux_menu_sync();
    // Keep fetching when a batch contained only captured input, so later quit/window events are not delayed.
    for (;;) {
        int count = lm_peep(events, capacity, action, minimum, maximum);
        if (lm_polling || !lm_ready || count <= 0 || action != 2 || !events) return count;
        int kept = 0;
        for (int i = 0; i < count; i++) if (linux_menu_filter(&events[i])) events[kept++] = events[i];
        if (kept) return kept;
    }
}

__declspec(dllexport) const bool *SDL_GetKeyboardState(int *count)
{
    linux_menu_init();
    int size = 0;
    const bool *keys = lm_keys ? lm_keys(&size) : NULL;
    if (count) *count = size;
    if (keys && size <= (int)sizeof lm_empty_keys) {
        int scan = menu_hotkey_scan(g_menuHotkey);
        if (!lm_captured_window && (scan >= size || !keys[scan] || g_menuPresetNaming || g_menuSearchFocus)) return keys;
        if (lm_captured_window) memset(lm_empty_keys, 0, sizeof lm_empty_keys);
        else {
            memcpy(lm_empty_keys, keys, size);
            lm_empty_keys[scan] = false;
        }
        return lm_empty_keys;
    }
    return keys;
}

#define LM_MOUSE_WRAPPER(name, real, savedX, savedY) \
__declspec(dllexport) uint32_t name(float *x, float *y) { \
    linux_menu_init(); \
    uint32_t buttons = real ? real(x, y) : 0; \
    if (lm_captured_window) { if (x) *x = savedX; if (y) *y = savedY; return 0; } \
    return buttons & ~lm_buttons; \
}
LM_MOUSE_WRAPPER(SDL_GetMouseState, lm_mouse, lm_saved_x, lm_saved_y)
LM_MOUSE_WRAPPER(SDL_GetGlobalMouseState, lm_global, lm_global_x, lm_global_y)
LM_MOUSE_WRAPPER(SDL_GetRelativeMouseState, lm_relative, 0, 0)
#undef LM_MOUSE_WRAPPER

__declspec(dllexport) bool SDL_SetWindowRelativeMouseMode(void *window, bool enabled)
{
    linux_menu_init();
    if (lm_captured_window == window && window) { lm_saved_relative = enabled; enabled = false; }
    return lm_set_relative ? lm_set_relative(window, enabled) : false;
}
__declspec(dllexport) bool SDL_SetWindowMouseGrab(void *window, bool enabled)
{
    linux_menu_init();
    if (lm_captured_window == window && window) { lm_saved_grab = enabled; enabled = false; }
    return lm_set_grab ? lm_set_grab(window, enabled) : false;
}

static void *linux_menu_lookup(const char *name)
{
#define LM_HOOK(fn) if (!strcmp(name, #fn)) return (void *)fn
#if AU_HAS_UPSCALER
    LM_HOOK(SDL_GetWindowSizeInPixels);
#endif
    LM_HOOK(SDL_PollEvent); LM_HOOK(SDL_PeepEvents); LM_HOOK(SDL_GetKeyboardState);
    LM_HOOK(SDL_GetMouseState); LM_HOOK(SDL_GetGlobalMouseState); LM_HOOK(SDL_GetRelativeMouseState);
    LM_HOOK(SDL_SetWindowRelativeMouseMode); LM_HOOK(SDL_SetWindowMouseGrab);
#undef LM_HOOK
    return NULL;
}
