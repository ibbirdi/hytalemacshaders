// Draws the in-game menu with the macOS panel (hook/mac_panel.h) into a PNG, to look at it
// without the game:  tools/macos_test/menu_test.sh [output.png]
#include "../../hook/hook.c"
#include <ImageIO/ImageIO.h>

int main(int argumentCount, char **arguments)
{
    const char *output = argumentCount > 2 ? arguments[2] : "build/menu.png";
    MultiByteToWideChar(CP_UTF8, 0, arguments[1], -1, g_packDir, MAX_PATH);
    QueryPerformanceFrequency(&g_freq);
    InitializeCriticalSection(&g_menuLock);
    settings_load();
    menu_load();
    g_menuOpen = 1;
    menu_render(1600, 1000);
    if (!g_ovBits) { fprintf(stderr, "the panel did not draw\n"); return 1; }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(g_ovBits, g_ovTexW, g_ovTexH, 8, (size_t)g_ovTexW * 4, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)output, (CFIndex)strlen(output), false);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    int written = CGImageDestinationFinalize(destination);
    printf("%s %dx%d: %s\n", output, g_ovTexW, g_ovTexH, written ? "written" : "failed");
    return !written;
}
