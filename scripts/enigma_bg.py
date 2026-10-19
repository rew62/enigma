#!/usr/bin/env python3
# enigma_bg.py - wallpaper sampler for draw_bg.lua's automatic pane opacity
#
# One resident copy serves the whole suite: draw_bg.lua starts it detached
# when its pid file is stale, and a lock makes any extra copy exit at once.
# --once does a single scan and exits (draw_bg.lua runs it synchronously on
# a widget's first draw when no sample for it exists yet).
# It reads the desktop's rendered background (_XROOTPMAP_ID, scaling already
# applied), finds every conky window whose rc basename a widget registered
# under MEMBERS_DIR, and writes the 94th-percentile-luminance pixel behind
# each to SAMPLES as a Lua table literal, bumping SERIAL when they change.
# The alpha solve itself lives in draw_bg.lua, so every setting stays in
# settings.lua and this script takes no configuration.
#
# Rescans are event-driven: X tells us when the background property changes
# or any top-level window maps/moves/resizes, plus a slow FALLBACK_EVERY run
# for anything those miss (a background redrawn in place). Exits after
# IDLE_EXIT seconds with no registered widget on screen.
#
# Needs python3-xlib and python3-numpy. X11 only.
# v1 2026-10-19 @rew62

import fcntl
import os
import select
import sys
import time

import numpy as np
from Xlib import X, display, error

BG_DIR = "/dev/shm/enigma/bg"
MEMBERS_DIR = BG_DIR + "/members"
SAMPLES = BG_DIR + "/samples.lua"
SERIAL = BG_DIR + "/serial"
PIDFILE = BG_DIR + "/pid"
LOCK = BG_DIR + "/lock"

PERCENTILE = 0.94
SETTLE = (0.3, 2.5)      # rescan delays after an event; the second catches fades
FALLBACK_EVERY = 30
IDLE_EXIT = 120


def log(msg):
    print(time.strftime("%H:%M:%S"), "enigma_bg:", msg, flush=True)


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


class Sampler:
    def __init__(self):
        self.d = display.Display()
        self.root = self.d.screen().root
        self.WM_COMMAND = self.d.intern_atom("WM_COMMAND")
        self.ROOTPMAP = self.d.intern_atom("_XROOTPMAP_ID")
        self.root.change_attributes(
            event_mask=X.PropertyChangeMask | X.SubstructureNotifyMask)
        self.last_text = None
        self.warned = False

    def conky_windows(self):
        """{rc basename: (x, y, w, h)} for every viewable conky window."""
        found = {}

        def walk(w):
            try:
                kids = w.query_tree().children
            except error.XError:
                return
            for c in kids:
                try:
                    p = c.get_full_property(self.WM_COMMAND, X.AnyPropertyType)
                    if p:
                        argv = p.value.split(b"\0")
                        if os.path.basename(argv[0]).startswith(b"conky") and b"-c" in argv:
                            rc = argv[argv.index(b"-c") + 1].decode(errors="replace")
                            if c.get_attributes().map_state == X.IsViewable:
                                g = c.get_geometry()
                                t = c.translate_coords(self.root, 0, 0)
                                found[os.path.basename(rc)] = (-t.x, -t.y, g.width, g.height)
                            continue
                except error.XError:
                    continue
                walk(c)

        walk(self.root)
        return found

    def background(self):
        p = self.root.get_full_property(self.ROOTPMAP, X.AnyPropertyType)
        if not p or not p.value:
            return None
        pm = self.d.create_resource_object("pixmap", p.value[0])
        try:
            g = pm.get_geometry()
        except error.XError:
            return None
        return pm, g.width, g.height

    def sample(self, bg, rect):
        pm, pw, ph = bg
        x, y, w, h = rect
        x0, y0 = max(x, 0), max(y, 0)
        x1, y1 = min(x + w, pw), min(y + h, ph)
        if x1 <= x0 or y1 <= y0:
            return None
        img = pm.get_image(x0, y0, x1 - x0, y1 - y0, X.ZPixmap, 0xFFFFFFFF)
        # 24-bit depth arrives as 32bpp BGRX
        px = np.frombuffer(img.data, np.uint8).reshape(-1, 4)[:, 2::-1] / 255.0
        lin = to_linear(px)
        lum = lin @ np.array([0.2126, 0.7152, 0.0722])
        i = np.argpartition(lum, int(PERCENTILE * (len(lum) - 1)))[int(PERCENTILE * (len(lum) - 1))]
        return px[i]

    def rescan(self):
        """Returns the number of registered widgets found on screen."""
        try:
            members = set(os.listdir(MEMBERS_DIR))
        except OSError:
            members = set()
        wins = {k: v for k, v in self.conky_windows().items() if k in members}
        if not wins:
            return 0
        bg = self.background()
        if bg is None:
            if not self.warned:
                log("no _XROOTPMAP_ID background; panes keep their last opacity")
                self.warned = True
            return len(wins)
        self.warned = False
        lines = ["return {"]
        for name in sorted(wins):
            try:
                rgb = self.sample(bg, wins[name])
            except error.XError:
                continue
            if rgb is not None:
                key = name.replace("\\", "\\\\").replace('"', '\\"')
                lines.append('  ["%s"] = { %.4f, %.4f, %.4f },' % (key, *rgb))
        lines.append("}")
        text = "\n".join(lines) + "\n"
        if text != self.last_text:
            write_atomic(SAMPLES, text)
            write_atomic(SERIAL, "%d\n" % time.time_ns())
            self.last_text = text
        return len(wins)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main():
    os.makedirs(MEMBERS_DIR, exist_ok=True)
    if "--once" in sys.argv:
        # draw_bg.lua's first draw: a widget with a long update_interval
        # would otherwise keep the pane it drew before any sample existed
        Sampler().rescan()
        return 0
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    write_atomic(PIDFILE, "%d\n" % os.getpid())

    s = Sampler()
    log("started, pid %d" % os.getpid())
    # settle: rescan times after the latest X event, replaced by each new
    # event so a window drag rescans once it stops rather than per motion
    settle = []
    last_scan = 0.0
    last_seen = time.monotonic()
    members_mtime = None
    fd = s.d.fileno()

    while True:
        now = time.monotonic()
        try:
            mt = os.stat(MEMBERS_DIR).st_mtime_ns
        except OSError:
            mt = None
        scan = mt != members_mtime or now - last_scan >= FALLBACK_EVERY
        members_mtime = mt
        if settle and settle[0] <= now:
            settle.pop(0)
            scan = True

        if scan:
            last_scan = now
            if s.rescan():
                last_seen = now
            elif now - last_seen > IDLE_EXIT:
                log("no enigma widgets on screen for %ds, exiting" % IDLE_EXIT)
                return 0

        timeout = 1.0 if not settle else min(1.0, max(settle[0] - time.monotonic(), 0))
        if not s.d.pending_events():
            select.select([fd], [], [], timeout)
        event = False
        while s.d.pending_events():
            e = s.d.next_event()
            if e.type == X.PropertyNotify and e.atom != s.ROOTPMAP:
                continue
            event = True
        if event:
            t = time.monotonic()
            settle = [t + d for d in SETTLE]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except error.DisplayError as e:
        log("cannot open display: %s" % e)
        sys.exit(1)
