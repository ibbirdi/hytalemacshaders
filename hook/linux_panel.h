// Cairo replaces the Windows GDI panel; the OpenGL overlay and menu model are shared. macOS draws
// the same panel with CoreGraphics and CoreText instead (mac_panel.h), so it needs no Homebrew.
#ifdef __APPLE__
#include "mac_panel.h"
#else
typedef struct { double px; int bold; } LinuxFont;
typedef cairo_t *PanelDC;
static cairo_t *g_ovDC;
static cairo_surface_t *g_ovBmp;
static unsigned char *g_ovBits;
static int g_ovW, g_ovH, g_ovTexW, g_ovTexH, g_ovScreenH, g_ovScreenW, g_ovUpload;
static LinuxFont g_fText, g_fBold, g_fSmall;
#define RGB(r, g, b) (((r) << 16) | ((g) << 8) | (b))
#define DT_LEFT 0
#define DT_RIGHT 1
#define DT_CENTER 2
typedef unsigned COLORREF;

static int linux_panel_resize(int w, int h)
{
    if (g_ovBmp && g_ovBits && g_ovW == w && g_ovH == h) return 1;
    if (g_ovDC) cairo_destroy(g_ovDC);
    if (g_ovBmp) cairo_surface_destroy(g_ovBmp);
    g_ovBmp = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * 2, h * 2);
    g_ovDC = cairo_create(g_ovBmp);
    cairo_font_options_t *options = cairo_font_options_create();
    cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
    cairo_set_font_options(g_ovDC, options);
    cairo_font_options_destroy(options);
    g_ovBits = NULL;
    if (cairo_status(g_ovDC) != CAIRO_STATUS_SUCCESS) return 0;
    g_ovBits = cairo_image_surface_get_data(g_ovBmp);
    // Display size stays in menu coordinates; the backing surface is supersampled.
    g_ovW = w; g_ovH = h;
    return 1;
}
static void linux_color(PanelDC dc, unsigned c)
{
    cairo_set_source_rgb(dc, ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0);
}
static void menu_fill(PanelDC dc, int x0, int y0, int x1, int y1, unsigned c)
{
    cairo_surface_mark_dirty(g_ovBmp);
    linux_color(dc, c);
    cairo_rectangle(dc, x0, y0, x1 - x0, y1 - y0);
    cairo_fill(dc);
}
static void menu_text(PanelDC dc, const wchar_t *s, int x0, int y0, int x1, int y1,
                      LinuxFont font, unsigned c, unsigned align)
{
    char text[1024];
    au_to_utf8(text, sizeof text, s);
    cairo_save(dc);
    cairo_rectangle(dc, x0, y0, x1 - x0, y1 - y0);
    cairo_clip(dc);
    cairo_select_font_face(dc, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL,
                           font.bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(dc, font.px);
    cairo_text_extents_t ext;
    cairo_text_extents(dc, text, &ext);
    linux_color(dc, c);
    cairo_move_to(dc, align == DT_RIGHT ? x1 - ext.x_advance : align == DT_CENTER ? (x0 + x1 - ext.x_advance) * 0.5 : x0,
                  y0 + (y1 - y0 - ext.height) / 2 - ext.y_bearing);
    cairo_show_text(dc, text);
    cairo_restore(dc);
}

static void menu_round(PanelDC dc, int left, int top, int right, int bottom, int radius, unsigned color)
{
    double corner = fmin(radius * 0.5, fmin(right - left, bottom - top) * 0.5);
    linux_color(dc, color);
    cairo_new_sub_path(dc);
    cairo_arc(dc, right - corner, top + corner, corner, -1.57079632679, 0);
    cairo_arc(dc, right - corner, bottom - corner, corner, 0, 1.57079632679);
    cairo_arc(dc, left + corner, bottom - corner, corner, 1.57079632679, 3.14159265359);
    cairo_arc(dc, left + corner, top + corner, corner, 3.14159265359, 4.71238898038);
    cairo_close_path(dc);
    cairo_fill(dc);
}

// Menu coordinates on the supersampled surface, before drawing a frame; then hand it to OpenGL.
static void linux_panel_begin(void)
{
    cairo_identity_matrix(g_ovDC);
    cairo_scale(g_ovDC, 2.0, 2.0);
}

static void linux_panel_flush(void)
{
    cairo_surface_flush(g_ovBmp);
}
#endif
