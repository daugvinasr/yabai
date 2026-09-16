extern struct event_loop g_event_loop;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern char g_version_string[MAXLEN];

// Event loop thread only; the main thread only ever looks at g_si_item.
static bool g_si_refresh_pending;

static void status_indicator_request_refresh(void);

// Main thread only.
static NSStatusItem *g_si_item;
static id g_si_menu_target;
static NSMutableDictionary *g_si_symbol_cache;
static struct status_indicator_cell *g_si_last_cells;
static int g_si_last_count;

static void status_indicator_exec_self(const char *option)
{
    char exe_path[4096];
    uint32_t exe_path_size = sizeof(exe_path);
    if (_NSGetExecutablePath(exe_path, &exe_path_size) < 0) return;

    const char *const args[] = { exe_path, option, NULL };
    safe_exec((char *const*)args, true);
}

@interface status_indicator_menu_target : NSObject
- (void)restartService:(id)sender;
- (void)stopService:(id)sender;
@end

@implementation status_indicator_menu_target
- (void)restartService:(id)sender
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        status_indicator_exec_self("--restart-service");
    });
}

- (void)stopService:(id)sender
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        status_indicator_exec_self("--stop-service");
    });
}
@end

// SF Symbol images pad the glyph with margins (a "2.square" at pointSize 40 is
// a 46x41 image holding a 36x35 glyph). Naively aspect-fitting the image shrinks
// the visible square and inflates the gaps, so measure the glyph's actual alpha
// bounding box and scale by that instead.
static bool status_indicator_alpha_bounds(NSImage *image, NSRect *bounds)
{
    int w = (int) ceil(image.size.width * 2);
    int h = (int) ceil(image.size.height * 2);

    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                     pixelsWide:w
                                                                     pixelsHigh:h
                                                                  bitsPerSample:8
                                                                samplesPerPixel:4
                                                                       hasAlpha:YES
                                                                       isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace
                                                                    bytesPerRow:0
                                                                   bitsPerPixel:0] autorelease];
    if (!rep) return false;

    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) return false;

    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [image drawInRect:NSMakeRect(0, 0, w, h)];
    [NSGraphicsContext restoreGraphicsState];

    unsigned char *data = rep.bitmapData;
    if (!data) return false;

    NSInteger bpr = rep.bytesPerRow;
    NSInteger spp = rep.samplesPerPixel;
    int min_x = w, max_x = -1, min_y = h, max_y = -1;

    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            if (data[y * bpr + x * spp + 3] <= 25) continue;
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
        }
    }

    if (max_x < min_x) return false;

    // bitmap rows are top-down; convert back to bottom-up point coords
    CGFloat fx = image.size.width  / w;
    CGFloat fy = image.size.height / h;
    *bounds = NSMakeRect(min_x * fx,
                         (h - 1 - max_y) * fy,
                         (max_x - min_x + 1) * fx,
                         (max_y - min_y + 1) * fy);
    return true;
}

static bool status_indicator_symbol(NSString *name, NSImage **image, NSRect *glyph)
{
    NSArray *cached = g_si_symbol_cache[name];
    if (cached) {
        *image = cached[0];
        *glyph = [cached[1] rectValue];
        return true;
    }

    NSImage *symbol = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!symbol) return false;

    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:40 weight:NSFontWeightRegular];
    symbol = [symbol imageWithSymbolConfiguration:config];
    if (!symbol) return false;

    NSRect bounds;
    if (!status_indicator_alpha_bounds(symbol, &bounds)) return false;

    g_si_symbol_cache[name] = @[symbol, [NSValue valueWithRect:bounds]];
    *image = symbol;
    *glyph = bounds;
    return true;
}

// i3-style ordered squares. Numeric spaces use the SF Symbols "N.square.fill"
// (focused) / "N.square"; spaces not currently visible are drawn dimmed, and
// spaces holding a fullscreen window (native or yabai zoom-fullscreen) get a
// dashed rounded border, with the glyph inset to make room.
static NSImage *status_indicator_image(struct status_indicator_cell *cells, int count)
{
    CGFloat item_size = 20;
    CGFloat spacing   = 3;
    CGFloat width     = item_size * count + spacing * (count > 0 ? count - 1 : 0);

    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(width, item_size)] autorelease];
    [image lockFocus];

    CGFloat x = 0;
    for (int i = 0; i < count; ++i) {
        struct status_indicator_cell *cell = &cells[i];
        NSRect box = NSMakeRect(x, 0, item_size, item_size);

        // Three tiers: on screen, off screen with windows, off screen and empty.
        CGFloat alpha = cell->visible ? 1.0 : cell->occupied ? 0.5 : 0.25;

        if (cell->fullscreen) {
            // Stroke straddles the path, so pull it half a linewidth inward to
            // keep it inside the box.
            NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:2.5 yRadius:2.5];
            CGFloat dash[] = { 4, 2 };
            border.lineWidth = 1;
            [border setLineDash:dash count:2 phase:1];
            [[NSColor.blackColor colorWithAlphaComponent:alpha] setStroke];
            [border stroke];
            box = NSInsetRect(box, 3, 3);
        }

        NSString *symbol_name = [NSString stringWithFormat:@"%d.square%@", cell->index, cell->focused ? @".fill" : @""];
        NSImage *symbol;
        NSRect glyph;
        if (status_indicator_symbol(symbol_name, &symbol, &glyph)) {
            CGFloat scale = fmin(box.size.width / glyph.size.width, box.size.height / glyph.size.height);
            NSRect draw_rect = NSMakeRect(NSMidX(box) - NSMidX(glyph) * scale,
                                          NSMidY(box) - NSMidY(glyph) * scale,
                                          symbol.size.width * scale,
                                          symbol.size.height * scale);
            [symbol drawInRect:draw_rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha];
        } else {
            // No SF Symbol beyond 50; fall back to a plain number.
            NSDictionary *attributes = @{
                NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: [NSColor.blackColor colorWithAlphaComponent:alpha],
            };
            NSAttributedString *text = [[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%d", cell->index]
                                                                        attributes:attributes] autorelease];
            NSSize text_size = text.size;
            [text drawAtPoint:NSMakePoint(NSMidX(box) - text_size.width / 2, NSMidY(box) - text_size.height / 2)];
        }

        x += item_size + spacing;
    }

    [image unlockFocus];
    image.template = YES;
    return image;
}

static void status_indicator_render(struct status_indicator_cell *cells, int count)
{
    if (!g_si_item) {
        free(cells);
        return;
    }

    // Skip re-rendering (and the menu bar redraw) when nothing changed.
    if (g_si_last_cells &&
        g_si_last_count == count &&
        memcmp(g_si_last_cells, cells, count * sizeof(struct status_indicator_cell)) == 0) {
        free(cells);
        return;
    }

    free(g_si_last_cells);
    g_si_last_cells = cells;
    g_si_last_count = count;

    @autoreleasepool {
        g_si_item.button.title = @"";
        g_si_item.button.image = status_indicator_image(cells, count);
    }
}

static void status_indicator_create(void)
{
    if (g_si_item) return;

    // A bare executable starts out with the prohibited policy, under which
    // the window server never shows its status items; accessory keeps it out
    // of the Dock and the app switcher.
    if (NSApp.activationPolicy != NSApplicationActivationPolicyAccessory) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }

    g_si_symbol_cache = [[NSMutableDictionary alloc] init];
    g_si_menu_target  = [[status_indicator_menu_target alloc] init];

    NSMenu *menu = [[[NSMenu alloc] init] autorelease];
    NSMenuItem *about = [menu addItemWithTitle:[NSString stringWithUTF8String:g_version_string] action:nil keyEquivalent:@""];
    about.enabled = NO;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *restart = [menu addItemWithTitle:@"Restart yabai" action:@selector(restartService:) keyEquivalent:@"r"];
    restart.target = g_si_menu_target;
    NSMenuItem *stop = [menu addItemWithTitle:@"Stop yabai" action:@selector(stopService:) keyEquivalent:@"x"];
    stop.target = g_si_menu_target;

    g_si_item = [[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength] retain];
    g_si_item.button.title = @"?";
    g_si_item.menu = menu;
}

void status_indicator_begin(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        status_indicator_create();
    });
    status_indicator_request_refresh();
}

// Coalesces bursts (e.g. window_moved firing on every frame of a drag) into a
// single snapshot, taken on the event loop thread once things settle.
static void status_indicator_request_refresh(void)
{
    if (g_si_refresh_pending) return;
    g_si_refresh_pending = true;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, STATUS_INDICATOR_REFRESH, NULL, 0);
    });
}

void status_indicator_notify_event(enum event_type type)
{
    switch (type) {
    // Fire continuously and never change what the indicator shows.
    case MOUSE_MOVED:
    case MOUSE_DRAGGED:
    case MENU_OPENED:
    case MENU_CLOSED:
    case MISSION_CONTROL_CHECK_FOR_EXIT:
    case STATUS_INDICATOR_REFRESH:
        return;
    default:
        status_indicator_request_refresh();
    }
}

// Whether a window counts toward its space being "occupied". Windows yabai has
// no AX reference for are ghosts: Electron apps like Bitwarden "close to tray"
// by ordering the window out rather than destroying it, and macOS keeps it
// assigned to its space. Sticky windows (e.g. CleanShot X's overlay) belong to
// every space.
static bool status_indicator_window_occupies(struct window *window)
{
    if (!window) return false;
    if (window_check_flag(window, WINDOW_STICKY)) return false;
    return !window_is_sticky(window->id);
}

static bool status_indicator_window_is_fullscreen(struct window *window)
{
    if (!window) return false;
    if (window_check_flag(window, WINDOW_FULLSCREEN)) return true;

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    struct window_node *node = view ? view_find_window_node(view, window->id) : NULL;
    return node && node->zoom && node->zoom == view->root;
}

// Event loop thread: snapshot every space (empty or not; the row should only
// change width when a space is actually created or destroyed, emptiness is
// signalled by opacity) and hand the cells to the main thread for drawing.
void status_indicator_refresh(void)
{
    g_si_refresh_pending = false;

    TIME_FUNCTION;

    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    int capacity = 0;
    for (int i = 0; i < display_count; ++i) {
        int space_count;
        if (display_space_list(display_list[i], &space_count)) capacity += space_count;
    }

    struct status_indicator_cell *cells = malloc(sizeof(struct status_indicator_cell) * (capacity ? capacity : 1));
    int count = 0;

    uint64_t active_sid = space_manager_active_space();

    for (int i = 0; i < display_count && count < capacity; ++i) {
        uint64_t visible_sid = display_space_id(display_list[i]);

        int space_count;
        uint64_t *space_list = display_space_list(display_list[i], &space_count);
        if (!space_list) continue;

        for (int j = 0; j < space_count && count < capacity; ++j) {
            uint64_t sid = space_list[j];

            int window_count = 0;
            uint32_t *window_list = space_window_list(sid, &window_count, true);

            bool occupied = false;
            bool fullscreen = space_is_fullscreen(sid);
            for (int k = 0; k < window_count && !(occupied && fullscreen); ++k) {
                struct window *window = window_manager_find_window(&g_window_manager, window_list[k]);
                if (!occupied   && status_indicator_window_occupies(window))      occupied   = true;
                if (!fullscreen && status_indicator_window_is_fullscreen(window)) fullscreen = true;
            }

            cells[count++] = (struct status_indicator_cell) {
                .index      = space_manager_mission_control_index(sid),
                .focused    = sid == active_sid,
                .visible    = sid == visible_sid,
                .occupied   = occupied,
                .fullscreen = fullscreen,
            };
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        status_indicator_render(cells, count);
    });
}
