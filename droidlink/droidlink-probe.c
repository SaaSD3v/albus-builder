#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xdamage.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/XTest.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int g_xerr = 0;
static int trap_xerror(Display *dpy, XErrorEvent *e) {
    (void)dpy;
    g_xerr = e->error_code ? e->error_code : 1;
    return 0;
}

static double ms_since(const struct timespec *a, const struct timespec *b) {
    return (b->tv_sec - a->tv_sec) * 1000.0 + (b->tv_nsec - a->tv_nsec) / 1000000.0;
}

static uint64_t checksum_sample(const XImage *img) {
    if (!img || !img->data || img->bytes_per_line <= 0 || img->height <= 0) return 0;
    size_t total = (size_t)img->bytes_per_line * (size_t)img->height;
    const unsigned char *p = (const unsigned char *)img->data;
    uint64_t h = 1469598103934665603ULL;
    size_t step = total > 65536 ? total / 65536 : 1;
    for (size_t i = 0; i < total; i += step) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int wait_damage(Display *dpy, int damage_event_base, Window w, GC gc) {
    Damage damage = XDamageCreate(dpy, w, XDamageReportRawRectangles);
    if (!damage) return 0;
    XSync(dpy, False);

    XSetForeground(dpy, gc, 0x00ff00);
    XFillRectangle(dpy, w, gc, 3, 3, 24, 24);
    XFlush(dpy);

    for (int i = 0; i < 100; ++i) {
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == damage_event_base + XDamageNotify) {
                XDamageNotifyEvent *de = (XDamageNotifyEvent *)&ev;
                printf("Damage event  YES  %dx%d+%d+%d\n",
                       de->area.width, de->area.height, de->area.x, de->area.y);
                XDamageDestroy(dpy, damage);
                return 1;
            }
        }
        struct timespec req = { .tv_sec = 0, .tv_nsec = 10000000L };
        nanosleep(&req, NULL);
    }

    XDamageDestroy(dpy, damage);
    return 0;
}

int main(void) {
    const char *disp = getenv("DISPLAY");
    printf("DroidLink Probe 0.1\n\n");
    printf("DISPLAY       %s\n", disp && *disp ? disp : "<unset>");

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "RESULT        BLOCKED: cannot open DISPLAY\n");
        return 2;
    }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    int width = DisplayWidth(dpy, screen);
    int height = DisplayHeight(dpy, screen);
    int depth = DefaultDepth(dpy, screen);
    Visual *visual = DefaultVisual(dpy, screen);
    printf("Screen        %dx%dx%d\n", width, height, depth);

    int ev = 0, err = 0;
    int damage_ok = XDamageQueryExtension(dpy, &ev, &err);
    int damage_event_base = ev;
    int xfixes_ok = XFixesQueryExtension(dpy, &ev, &err);
    int xtest_event = 0, xtest_error = 0, xtest_major = 0, xtest_minor = 0;
    int xtest_ok = XTestQueryExtension(dpy, &xtest_event, &xtest_error, &xtest_major, &xtest_minor);
    int shm_ok = XShmQueryExtension(dpy);

    printf("DAMAGE        %s\n", damage_ok ? "YES" : "NO");
    printf("MIT-SHM       %s (advertised)\n", shm_ok ? "YES" : "NO");
    printf("XFIXES        %s\n", xfixes_ok ? "YES" : "NO");
    printf("XTEST         %s\n", xtest_ok ? "YES" : "NO");

    int shm_attached = 0;
    double shm_capture_ms = -1.0;
    uint64_t shm_checksum = 0;
    XImage *shm_img = NULL;
    XShmSegmentInfo si;
    memset(&si, 0, sizeof(si));
    si.shmid = -1;
    si.shmaddr = (char *)-1;

    if (shm_ok) {
        shm_img = XShmCreateImage(dpy, visual, (unsigned int)depth, ZPixmap, NULL, &si,
                                  (unsigned int)width, (unsigned int)height);
        if (shm_img) {
            size_t bytes = (size_t)shm_img->bytes_per_line * (size_t)shm_img->height;
            si.shmid = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600);
            if (si.shmid >= 0) {
                si.shmaddr = shmat(si.shmid, NULL, 0);
                if (si.shmaddr != (char *)-1) {
                    shm_img->data = si.shmaddr;
                    si.readOnly = False;
                    int (*old_handler)(Display *, XErrorEvent *) = XSetErrorHandler(trap_xerror);
                    g_xerr = 0;
                    Status at = XShmAttach(dpy, &si);
                    XSync(dpy, False);
                    if (at && !g_xerr) {
                        shm_attached = 1;
                        struct timespec a, b;
                        clock_gettime(CLOCK_MONOTONIC, &a);
                        Status got = XShmGetImage(dpy, root, shm_img, 0, 0, AllPlanes);
                        XSync(dpy, False);
                        clock_gettime(CLOCK_MONOTONIC, &b);
                        if (got && !g_xerr) {
                            shm_capture_ms = ms_since(&a, &b);
                            shm_checksum = checksum_sample(shm_img);
                        }
                        XShmDetach(dpy, &si);
                        XSync(dpy, False);
                    }
                    XSetErrorHandler(old_handler);
                }
                shmctl(si.shmid, IPC_RMID, NULL);
            }
        }
    }

    if (shm_attached && shm_capture_ms >= 0.0) {
        printf("SHM attach    YES\n");
        printf("SHM capture   OK   %.3f ms  checksum=%016llx\n",
               shm_capture_ms, (unsigned long long)shm_checksum);
    } else {
        printf("SHM attach    NO\n");
        printf("SHM capture   unavailable; XGetImage fallback will be required\n");
    }

    if (shm_img) {
        shm_img->data = NULL;
        XDestroyImage(shm_img);
    }
    if (si.shmaddr != (char *)-1) shmdt(si.shmaddr);

    struct timespec xa, xb;
    clock_gettime(CLOCK_MONOTONIC, &xa);
    XImage *plain = XGetImage(dpy, root, 0, 0, (unsigned int)width, (unsigned int)height,
                              AllPlanes, ZPixmap);
    XSync(dpy, False);
    clock_gettime(CLOCK_MONOTONIC, &xb);
    int plain_ok = plain != NULL;
    if (plain) {
        printf("XGetImage     OK   %.3f ms  checksum=%016llx\n",
               ms_since(&xa, &xb), (unsigned long long)checksum_sample(plain));
        XDestroyImage(plain);
    } else {
        printf("XGetImage     FAIL\n");
    }

    int damage_test = 0;
    if (damage_ok) {
        Window w = XCreateSimpleWindow(dpy, root, 0, 0, 32, 32, 0, 0, 0);
        XSelectInput(dpy, w, ExposureMask | StructureNotifyMask);
        GC gc = XCreateGC(dpy, w, 0, NULL);
        XMapWindow(dpy, w);
        XSync(dpy, False);
        damage_test = wait_damage(dpy, damage_event_base, w, gc);
        printf("DAMAGE test   %s\n", damage_test ? "OK" : "FAIL/NO EVENT");
        XFreeGC(dpy, gc);
        XDestroyWindow(dpy, w);
        XSync(dpy, False);
    }

    if (xfixes_ok) {
        XFixesCursorImage *ci = XFixesGetCursorImage(dpy);
        if (ci) {
            printf("Cursor        OK   %ux%u at %d,%d\n",
                   ci->width, ci->height, ci->x, ci->y);
            XFree(ci);
        } else {
            printf("Cursor        FAIL\n");
        }
    }

    int xtest_test = 0;
    if (xtest_ok) {
        Window rr, cr;
        int rx, ry, wx, wy;
        unsigned int mask;
        if (XQueryPointer(dpy, root, &rr, &cr, &rx, &ry, &wx, &wy, &mask)) {
            if (XTestFakeMotionEvent(dpy, screen, rx, ry, CurrentTime)) {
                XSync(dpy, False);
                xtest_test = 1;
                printf("XTEST input   OK   motion to current position %d,%d\n", rx, ry);
            }
        }
        if (!xtest_test) printf("XTEST input   FAIL\n");
    }

    printf("\nRESULT        ");
    if (damage_test && xtest_test && plain_ok && shm_attached) {
        printf("CORE FAST PATH COMPATIBLE\n");
    } else if (damage_test && xtest_test && plain_ok) {
        printf("CORE COMPATIBLE; SHM NEEDS FALLBACK\n");
    } else {
        printf("PARTIAL/BLOCKED - inspect failures above\n");
    }

    XCloseDisplay(dpy);
    return 0;
}
