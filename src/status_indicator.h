#ifndef STATUS_INDICATOR_H
#define STATUS_INDICATOR_H

//
// Menu bar space indicator: an i3-style row of numbered squares (one per
// mission-control space) drawn into an NSStatusItem, after AeroSpace's
// MenuBarLabel (.i3Ordered).
//
// State is gathered on the event loop thread (the owner of the space and
// window managers) and only the finished cells are handed to the main thread,
// where AppKit draws them.
//

// What actually gets drawn for one space; equality drives the redraw skip.
struct status_indicator_cell
{
    int index;
    bool focused;
    bool visible;
    bool occupied;
    bool fullscreen;
};

void status_indicator_begin(void);
void status_indicator_notify_event(enum event_type type);
void status_indicator_refresh(void);

#endif
