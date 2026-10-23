// SDL pixel sizes reported to Hytale describe its internal render resolution.
// The overlay and DLSS output always use the original physical size query.
#if AU_HAS_UPSCALER
static void *linux_render_window;
static bool (*linux_push_event)(LinuxMenuEvent *);
static void *(*linux_current_window)(void);
static int linux_render_width, linux_render_height;

__declspec(dllexport) bool SDL_GetWindowSizeInPixels(void *window, int *width, int *height);

static int linux_physical_size(int *width, int *height)
{
    void *window = linux_current_window ? linux_current_window() : NULL;
    if (!window) window = linux_render_window;
    return window && linux_sdl_size && linux_sdl_size(window, width, height) && *width > 0 && *height > 0;
}

static int linux_requested_scale(void)
{
    // Capability detection runs on the GL thread before any reduced-size resize.
    if (g_enabled && g_setDlssEnabled && g_dlssState == 1 && g_setRenderScale > 0)
        return g_setRenderScale;
    return 100;
}

static void linux_render_scale_sync(void)
{
    if (!linux_sdl_size || !lm_id || !linux_push_event) return;
    void *window = linux_current_window ? linux_current_window() : NULL;
    if (!window) return; // Only the thread with the game GL context can resize it.
    int width = 0, height = 0;
    if (!linux_sdl_size(window, &width, &height) || width <= 0 || height <= 0) return;
    int scale = linux_requested_scale();
    if (window == linux_render_window && scale == g_renderAppliedScale
        && width == linux_render_width && height == linux_render_height) return;
    linux_render_window = window;
    g_renderAppliedScale = scale;
    linux_render_width = width; linux_render_height = height;
    LinuxMenuEvent event = {0};
    event.type = 0x207; // SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
    uint32_t id = lm_id(window);
    int scaled_width = (width * scale + 50) / 100, scaled_height = (height * scale + 50) / 100;
    memcpy(event.bytes + 16, &id, sizeof id);
    memcpy(event.bytes + 20, &scaled_width, sizeof scaled_width);
    memcpy(event.bytes + 24, &scaled_height, sizeof scaled_height);
    if (!linux_push_event(&event)) {
        linux_render_width = linux_render_height = 0;
        logf_("render scale: SDL resize event could not be queued");
    } else logf_("render scale: %dx%d (%d%%), physical window %dx%d", scaled_width, scaled_height, scale, width, height);
}

static void linux_render_scale_event(LinuxMenuEvent *event)
{
    if (event->type != 0x207 || !linux_render_window || !lm_id
        || linux_menu_u32(event, 16) != lm_id(linux_render_window)) return;
    int width = 0, height = 0;
    if (!linux_sdl_size(linux_render_window, &width, &height)) return;
    width = (width * g_renderAppliedScale + 50) / 100;
    height = (height * g_renderAppliedScale + 50) / 100;
    memcpy(event->bytes + 20, &width, sizeof width);
    memcpy(event->bytes + 24, &height, sizeof height);
}

__declspec(dllexport) bool SDL_GetWindowSizeInPixels(void *window, int *width, int *height)
{
    pthread_once(&linux_init_once, linux_init);
    int w = 0, h = 0;
    if (!linux_sdl_size || !linux_sdl_size(window, &w, &h)) return false;
    int scale = window == linux_render_window ? g_renderAppliedScale : 100;
    if (width) *width = (w * scale + 50) / 100;
    if (height) *height = (h * scale + 50) / 100;
    return true;
}
#endif
