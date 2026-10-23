// The menu panel on macOS: CoreGraphics and CoreText in place of cairo (linux_panel.h), so the
// hook only needs what macOS ships. Same contract: a supersampled BGRA surface (premultiplied,
// top row first, as cairo's ARGB32) drawn in menu coordinates with the origin at the top left.
typedef struct { double px; int bold; } LinuxFont;
typedef CGContextRef PanelDC;
static CGContextRef g_ovDC;
static void *g_ovBmp;   // the surface's memory (CGBitmapContext draws straight into it)
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
    if (g_ovDC && g_ovBits && g_ovW == w && g_ovH == h) return 1;
    if (g_ovDC) CGContextRelease(g_ovDC);
    free(g_ovBmp);
    g_ovDC = NULL;
    g_ovBits = NULL;
    g_ovBmp = calloc((size_t)w * 2 * h * 2, 4);
    if (!g_ovBmp) return 0;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    g_ovDC = CGBitmapContextCreate(g_ovBmp, (size_t)w * 2, (size_t)h * 2, 8, (size_t)w * 2 * 4, space,
                                   kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!g_ovDC) return 0;
    CGContextSetShouldAntialias(g_ovDC, true);
    CGContextSetShouldSmoothFonts(g_ovDC, false);
    g_ovBits = g_ovBmp;
    // Display size stays in menu coordinates; the backing surface is supersampled.
    g_ovW = w; g_ovH = h;
    return 1;
}

// Menu coordinates (top-left origin, y down) at twice the size, before drawing a frame.
static void linux_panel_begin(void)
{
    CGContextConcatCTM(g_ovDC, CGAffineTransformInvert(CGContextGetCTM(g_ovDC)));
    CGContextTranslateCTM(g_ovDC, 0, g_ovH * 2.0);
    CGContextScaleCTM(g_ovDC, 2.0, -2.0);
}

static void linux_panel_flush(void)
{
    CGContextFlush(g_ovDC);
}

static void linux_color(PanelDC dc, unsigned c)
{
    CGContextSetRGBFillColor(dc, ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0, 1.0);
}

static void menu_fill(PanelDC dc, int x0, int y0, int x1, int y1, unsigned c)
{
    linux_color(dc, c);
    CGContextFillRect(dc, CGRectMake(x0, y0, x1 - x0, y1 - y0));
}

static CTFontRef mac_panel_font(LinuxFont font)
{
    static CTFontRef cache[2];
    static double cachedSize[2];
    int bold = font.bold != 0;
    if (!cache[bold] || cachedSize[bold] != font.px) {
        if (cache[bold]) CFRelease(cache[bold]);
        cache[bold] = CTFontCreateUIFontForLanguage(bold ? kCTFontUIFontEmphasizedSystem : kCTFontUIFontSystem, font.px, NULL);
        cachedSize[bold] = font.px;
    }
    return cache[bold];
}

static void menu_text(PanelDC dc, const wchar_t *s, int x0, int y0, int x1, int y1,
                      LinuxFont font, unsigned c, unsigned align)
{
    char text[1024];
    au_to_utf8(text, sizeof text, s);
    CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!string) return;
    CGColorRef color = CGColorCreateSRGB(((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0, 1.0);
    const void *keys[2] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *values[2] = {mac_panel_font(font), color};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CGFloat ascent = 0, descent = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    double x = align == DT_RIGHT ? x1 - width : align == DT_CENTER ? (x0 + x1 - width) * 0.5 : x0;
    double baseline = y0 + (y1 - y0 - (ascent + descent)) / 2 + ascent;
    CGContextSaveGState(dc);
    CGContextClipToRect(dc, CGRectMake(x0, y0, x1 - x0, y1 - y0));
    // The context runs y down; CoreText draws glyphs y up.
    CGContextSetTextMatrix(dc, CGAffineTransformMakeScale(1.0, -1.0));
    CGContextSetTextPosition(dc, x, baseline);
    CTLineDraw(line, dc);
    CGContextRestoreGState(dc);
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CGColorRelease(color);
    CFRelease(string);
}

static void menu_round(PanelDC dc, int left, int top, int right, int bottom, int radius, unsigned color)
{
    double corner = fmin(radius * 0.5, fmin(right - left, bottom - top) * 0.5);
    linux_color(dc, color);
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(left, top, right - left, bottom - top), corner, corner, NULL);
    CGContextAddPath(dc, path);
    CGContextFillPath(dc);
    CGPathRelease(path);
}
