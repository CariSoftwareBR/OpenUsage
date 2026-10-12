#!/usr/bin/env python3
# Floating Claude / Codex / Cursor / OpenCode Go usage widget for Linux.
# GTK 3 through PyGObject, which most desktops (GNOME, Cinnamon, MATE, Xfce...) already ship: nothing to build.
# Data comes from ../scripts/usage-json.ts, run with Node (>= 22.6).
# Usage: python3 widget-linux/openusage.py [--install | --uninstall]

import glob
import importlib
import json
import math
import os
import re
import shutil
import sys
import tempfile
import time
import uuid
import warnings

# Placing and pinning a window on top is up to the compositor on Wayland, so run through XWayland there.
if os.environ.get("WAYLAND_DISPLAY") and os.environ.get("DISPLAY"):
    os.environ.setdefault("GDK_BACKEND", "x11")

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango, PangoCairo  # noqa: E402
# Gradients (pycairo, python3-gi-cairo on Debian/Ubuntu): without it bars are a flat color and there's no sweep.
try:
    import cairo  # noqa: E402
except ImportError:
    cairo = None

# Tray: an AppIndicator when its typelib is installed, else the legacy X11 tray icon.
Indicator = None
for _name, _ver in (("AyatanaAppIndicator3", "0.1"), ("AppIndicator3", "0.1")):
    try:
        gi.require_version(_name, _ver)
        Indicator = importlib.import_module(f"gi.repository.{_name}")
        break
    except (ValueError, ImportError):
        pass

warnings.filterwarnings("ignore", category=DeprecationWarning)

REFRESH_MINUTES = 5
APP_ID = "com.openusage.widget"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_PATH = os.path.join(ROOT, "docs", "icon.png")
# The providers' own marks, one path each; the glyphs below stand in for any without one.
LOGO_DIR = os.path.join(ROOT, "assets", "providers")
ICONS = {
    "claude": "✻",
    "codex": "◎",
    "copilot": "◈",
    "cursor": "⬡",
    "devin": "◇",
    "grok": "✦",
    "kilo": "◆",
    "ollama": "◉",
    "opencode-go": "▣",
    "openrouter": "⇄",
    "zai": "▲",
}

# Services with no CLI sign-in: their API key is found on the machine or added in Settings (scripts/keys.ts).
KEYED_PROVIDERS = ["openrouter", "zai"]
# Every provider the widget offers, in the order the settings list them.
PROVIDER_NAMES = {
    "claude": "Claude", "codex": "Codex", "copilot": "Copilot", "cursor": "Cursor", "devin": "Devin", "grok": "Grok",
    "kilo": "Kilo", "ollama": "Ollama", "opencode-go": "OpenCode Go", "openrouter": "OpenRouter", "zai": "Z.ai",
}


def key_status(k):
    """No key yet, Saved here, Found in OpenCode, From OPENROUTER_API_KEY."""
    if not k:
        return "Looking for a key..."
    source = k.get("source")
    if not source:
        return "No key yet"
    if k.get("saved"):
        return "Saved here"
    if source.isupper() or "/" in source or "\\" in source:
        return f"From {source}"
    return f"Found in {source}"


HOME = os.path.expanduser("~")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share")
STATE_DIR = os.path.join(CONFIG_HOME, "usage-widget")
CACHE_FILE = os.path.join(STATE_DIR, "data.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")
NODE_FILE = os.path.join(STATE_DIR, "node.txt")
LAUNCHER_FILE = os.path.join(DATA_HOME, "applications", "openusage.desktop")
AUTOSTART_FILE = os.path.join(CONFIG_HOME, "autostart", "openusage.desktop")

# ---- settings and files --------------------------------------------------------------


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, value):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(value, f)
        os.replace(tmp, path)
    except OSError:
        pass


settings = read_json(SETTINGS_FILE, {})
if not isinstance(settings, dict):
    settings = {}


def save_setting(key, value):
    settings[key] = value
    write_json(SETTINGS_FILE, settings)


def is_exe(p):
    return bool(p) and os.path.isfile(p) and os.access(p, os.X_OK)


def find_node():
    """Launchers started from the app menu may not get the shell's PATH (nvm, say), so look around."""
    saved = None
    try:
        with open(NODE_FILE, encoding="utf-8") as f:
            saved = f.read().strip()
    except OSError:
        pass
    nvm = sorted(
        glob.glob(os.path.join(HOME, ".nvm", "versions", "node", "*", "bin", "node")),
        key=lambda p: [int(n) for n in re.findall(r"\d+", p.split(os.sep)[-3])],
    )
    for c in [os.environ.get("OPENUSAGE_NODE"), saved, shutil.which("node")] + nvm[::-1] + [
        os.path.join(HOME, ".volta", "bin", "node"),
        os.path.join(HOME, ".local", "bin", "node"),
        "/usr/local/bin/node",
        "/usr/bin/node",
    ]:
        if is_exe(c):
            return c
    return None


def desktop_quote(s):
    """Quotes one argument of a .desktop Exec line."""
    return '"' + re.sub(r'(["`$\\])', r"\\\1", s) + '"'


def desktop_entry(autostart=False):
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        "Name=OpenUsage",
        "Comment=AI coding plan limits in a floating widget",
        f"Exec={desktop_quote(sys.executable)} {desktop_quote(os.path.abspath(__file__))}",
        f"Icon={ICON_PATH}",
        "Terminal=false",
        "Categories=Utility;",
        "StartupWMClass=openusage",
    ]
    if autostart:
        lines.append("X-GNOME-Autostart-enabled=true")
    return "\n".join(lines) + "\n"


def write_text(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, mode)


def set_start_at_login(on):
    if on:
        write_text(AUTOSTART_FILE, desktop_entry(autostart=True))
    else:
        try:
            os.remove(AUTOSTART_FILE)
        except OSError:
            pass


# ---- theme (follows the desktop's light/dark) ----------------------------------------

LIGHT_DARK = {
    "bg": ("#FBFAF8", "#1C1A19"),
    "border": ("#E2DDD7", "#34302D"),
    "divider": ("#ECE8E3", "#2C2926"),
    "text": ("#1F1C1A", "#EBE7E2"),
    "muted": ("#857D76", "#8D8680"),
    "warn": ("#C46D12", "#E8953F"),
    "error": ("#C9362D", "#E5584F"),
    "track": ("#E4DED7", "#35302C"),
    "hover": ("#F1EDE8", "#2A2725"),
    "card": ("#F3F0EB", "#242120"),
    "cardBorder": ("#E8E3DD", "#2E2A27"),
    "ok": ("#2E8B57", "#5BBF86"),
    "claude": ("#D97757", "#D97757"),
    "codex": ("#0F8A6C", "#3DBE9C"),
    "copilot": ("#8250DF", "#A371F7"),
    "kilo": ("#A68A00", "#F2D33C"),
    "devin": ("#2563EB", "#60A5FA"),
    "openrouter": ("#4F46E5", "#818CF8"),
    "zai": ("#0E7490", "#22D3EE"),
}

C = {}


def interface_settings():
    source = Gio.SettingsSchemaSource.get_default()
    if source and source.lookup("org.gnome.desktop.interface", True):
        return Gio.Settings.new("org.gnome.desktop.interface")
    return None


def is_dark(iface):
    if iface is not None:
        schema = iface.props.settings_schema
        if schema.has_key("color-scheme") and iface.get_string("color-scheme") == "prefer-dark":
            return True
        if "dark" in iface.get_string("gtk-theme").lower():
            return True
    gs = Gtk.Settings.get_default()
    return bool(gs.props.gtk_application_prefer_dark_theme) or "dark" in (gs.props.gtk_theme_name or "").lower()


def apply_theme(dark):
    for k, v in LIGHT_DARK.items():
        C[k] = v[1 if dark else 0]


def level(pct):
    return C["error"] if pct >= 80 else C["warn"] if pct >= 50 else None


def rgb(hexcolor):
    h = hexcolor.lstrip("#")
    return tuple(int(h[i : i + 2], 16) / 255 for i in (0, 2, 4))


CSS = """
window.ou, window.ou decoration { background: transparent; box-shadow: none; border: none; }
.frame { background-color: @bg; border: 1px solid @border; border-radius: 12px; color: @text; }
.divider { background-color: @divider; min-height: 1px; }
.card { background-color: @card; border: 1px solid @cardBorder; border-radius: 8px; }
.ccard { background-color: @card; border: 1px solid @cardBorder; border-radius: 10px; }
.row { border-radius: 8px; transition: background-color 160ms ease-out; }
.row.hover { background-color: @hover; }
.frame.strip { border-radius: 23px; }
.chip { border-radius: 17px; }
.mark { background-color: @card; border-radius: 13px; }
.card, .ccard { transition: border-color 200ms ease-out; }
.card.hover, .ccard.hover { border-color: @border; }
.badge { background-color: @track; border-radius: 4px; padding: 1px 6px; }
button.hbtn { all: unset; color: @muted; padding: 2px 6px; border-radius: 5px; }
button.hbtn:hover { background-color: @hover; color: @text; }
.seg { background-color: @card; border: 1px solid @cardBorder; border-radius: 8px; padding: 3px; }
button.segbtn { all: unset; padding: 4px 8px; min-width: 62px; border-radius: 6px; color: @muted;
  transition: background-color 200ms ease-out, color 200ms ease-out; }
button.segbtn.on { background-color: @text; color: @bg; font-weight: 600; }
button.dbtn { all: unset; padding: 6px 14px; border-radius: 7px; background-color: @card;
  border: 1px solid @cardBorder; color: @text; transition: opacity 150ms ease-out; }
button.dbtn:hover { opacity: 0.85; }
button.dbtn.primary { background-color: @text; border-color: @text; color: @bg; font-weight: 600; }
button.dbtn:disabled { opacity: 0.4; }
switch { background-color: @track; background-image: none; border: none; border-radius: 10px; min-height: 18px;
    min-width: 34px; box-shadow: none; transition: background-color 160ms ease-out; color: transparent; font-size: 0; }
switch:checked { background-color: @text; }
switch:disabled { opacity: 0.4; }
switch slider { background-color: @bg; background-image: none; border: none; border-radius: 7px; min-height: 14px;
    min-width: 14px; margin: 2px; box-shadow: none; }
.status { background-color: @card; border: 1px solid @cardBorder; border-radius: 8px; }
"""


def css_text():
    defs = "".join(f"@define-color {k} {v};\n" for k, v in C.items())
    return defs + CSS


# ---- formatting ------------------------------------------------------------------------


def pango_size(px):
    # The Mac widget's sizes are in points on a 72 dpi grid; GTK text is in points on a 96 dpi one.
    return int(px * 0.75 * Pango.SCALE)


def span(text, size=13, color=None, weight=None, mono=False):
    attrs = [f'size="{pango_size(size)}"']
    if color:
        attrs.append(f'foreground="{color}"')
    if weight:
        attrs.append(f'weight="{weight}"')
    if mono:
        attrs.append('font_family="monospace"')
    return f"<span {' '.join(attrs)}>{GLib.markup_escape_text(text)}</span>"


def label(markup, xalign=0.0, ellipsize=False, wrap=False, tooltip=None):
    lb = Gtk.Label()
    lb.set_markup(markup)
    lb.set_xalign(xalign)
    if ellipsize:
        lb.set_ellipsize(Pango.EllipsizeMode.END)
    if wrap:
        lb.set_line_wrap(True)
        lb.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        lb.set_max_width_chars(1)
    if tooltip:
        lb.set_tooltip_text(tooltip)
    return lb


def _is_today(d):
    return time.localtime(time.time())[:3] == d[:3]


def format_reset(ms):
    if ms is None:
        return ""
    d = time.localtime(ms / 1000)
    t = time.strftime("%H:%M", d)
    return t if _is_today(d) else time.strftime("%a %d %b", d) + ", " + t


def format_reset_short(ms):
    """Shorter, for the compact rows: "14:00", "Wed 14:00" within the week, else "14 Oct"."""
    if ms is None:
        return ""
    d = time.localtime(ms / 1000)
    t = time.strftime("%H:%M", d)
    if _is_today(d):
        return t
    if ms / 1000 - time.time() < 6 * 86400:
        return time.strftime("%a", d) + " " + t
    return time.strftime("%d %b", d)


def format_ago(ms):
    if ms is None:
        return ""
    m = round((time.time() * 1000 - ms) / 60000)
    if m < 1:
        return "updated just now"
    if m < 60:
        return f"updated {m} min ago"
    return f"updated {round(m / 60)} h ago"


def uid(u):
    return u.get("key") or u["id"]


# ---- compact helpers -----------------------------------------------------------------
# One card per provider, one line per account with a ring pair: outer arc = weekly (or the billing cycle), inner = 5 hours.


def slots(u):
    ws = u.get("windows") or []
    short = next((w for w in ws if "Hour" in w["label"]), None)
    long = next((w for w in ws if "Week" in w["label"] or "7-Day Limit" in w["label"]), None)
    if long is None:
        long = next(
            (
                w
                for w in ws
                if (short is None or w["label"] != short["label"])
                and "Opus" not in w["label"]
                and "Sonnet" not in w["label"]
            ),
            None,
        )
    return short, long


def slot_name(w):
    lb = w["label"]
    if "Hour" in lb:
        return "5h"
    if "Week" in lb or "7-Day" in lb:
        return "wk"
    if "Month" in lb or "Billing" in lb:
        return "mo"
    return lb


def shown_pct(w, display):
    return w["usedPct"] if display == "used" else 100 - w["usedPct"]


def short_account(u):
    """"paulo" for paulo@example.com; without a known account, the profile folder (".claude-2") or nothing."""
    if u.get("account"):
        return u["account"].split("@")[0]
    m = re.search(r"\((.+)\)$", u["name"])
    return m.group(1) if m else ""


def tip_text(u, display):
    """Everything the ring leaves out: every limit with its reset, the plan and any error."""
    lines = [(u.get("account") or u["name"]) + (f"  -  {u['plan'].upper()}" if u.get("plan") else "")]
    for w in u.get("windows") or []:
        reset = format_reset(w.get("resetsAt"))
        lines.append(
            f"{w['label']}   {round(shown_pct(w, display))}% {'used' if display == 'used' else 'left'}"
            + (f"  -  resets {reset}" if reset else "")
        )
    for x in u.get("extras") or []:
        lines.append(f"{x['label']}   {x['value']}")
    if u.get("error"):
        lines.append(u["error"])
    return "\n".join(lines)


def groups(data):
    """Accounts grouped by provider, keeping the order providers arrive in."""
    order, by_id = [], {}
    for u in data:
        if u["id"] not in by_id:
            order.append(u["id"])
            by_id[u["id"]] = []
        by_id[u["id"]].append(u)
    return [(i, by_id[i]) for i in order]


# ---- logos and motion ----------------------------------------------------------------------

_logo_paths = {}
_logo_cache = {}
UI_SCALE = [1]


def logo_paths(pid):
    """(viewBox, [path data]) of a provider's mark, or None."""
    name = "opencode" if pid == "opencode-go" else pid
    if name not in _logo_paths:
        try:
            with open(os.path.join(LOGO_DIR, name + ".svg"), encoding="utf-8") as f:
                svg = f.read()
            vb = re.search(r'viewBox="([^"]+)"', svg)
            ds = re.findall(r'\sd="([^"]+)"', svg)
            _logo_paths[name] = (vb.group(1), ds) if vb and ds else None
        except OSError:
            _logo_paths[name] = None
    return _logo_paths[name]


def logo_surface(pid, color, size):
    """The mark in one color as a cairo surface of `size` logical pixels (sharp on HiDPI), via librsvg; None without it."""
    scale = UI_SCALE[0]
    key = (pid, color, size, scale)
    if key not in _logo_cache:
        surf = None
        src = logo_paths(pid)
        if src:
            px = int(round(size * scale))
            paths = "".join(f'<path fill="{color}" d="{d}"/>' for d in src[1])
            svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="{src[0]}">{paths}</svg>'
            try:
                loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
                loader.write(svg.encode())
                loader.close()
                surf = Gdk.cairo_surface_create_from_pixbuf(loader.get_pixbuf(), scale, None)
            except GLib.Error:
                surf = None
        _logo_cache[key] = surf
    return _logo_cache[key]


def logo(pid, color, size=13):
    """The provider's mark, or its glyph when there is none (or no SVG loader)."""
    surf = logo_surface(pid, color, size)
    if surf is None:
        lb = label(span(ICONS.get(pid, ""), size, color, "bold"))
        lb.set_valign(Gtk.Align.CENTER)
        return lb
    img = Gtk.Image.new_from_surface(surf)
    img.set_valign(Gtk.Align.CENTER)
    return img


def logo_title(pid, text, size=13.5, color=None, weight="bold"):
    """Mark + name, for card headers and settings rows."""
    row = hbox(7, logo(pid, color or C.get(pid, C["text"]), size + 0.5))
    row.pack_start(label(span(text, size, weight=weight)), False, False, 0)
    return row


def ease_out(k, power=3):
    return 1 - (1 - k) ** power


def animate(widget, ms, step, delay=0):
    """Calls step(eased 0..1) on every frame for `ms`, after `delay`; stops when the widget goes away."""
    def start():
        t0 = time.monotonic()

        def tick(*_):
            k = min(1, (time.monotonic() - t0) * 1000 / ms)
            step(k)
            return k < 1
        # Ticks start once the widget is on screen.
        widget.add_tick_callback(lambda w, clock: tick())
        return False
    if delay:
        GLib.timeout_add(delay, start)
    else:
        start()


def fade_in(widget, index, step=70, target=1.0):
    """First show of a layout or dialog: blocks fade in one after the other. (Moving them would resize the window.)"""
    widget.set_opacity(0)
    animate(widget, 420, lambda k: widget.set_opacity(target * ease_out(k)), delay=step * index)


def pulse(t, period=2.2):
    """0..1..0 breathing, for the glow of a limit at 80% or more."""
    return 0.5 - 0.5 * math.cos(2 * math.pi * t / period)


# ---- model -----------------------------------------------------------------------------


class Model:
    def __init__(self, changed):
        self.changed = changed
        self.data = []
        self.updated_at = None
        self.refreshing = False
        self.last_error = ""
        self.display = "remaining" if settings.get("display") == "remaining" else "used"
        self.layout = settings.get("layout") if settings.get("layout") in ("compact", "bar") else "normal"
        # How compact and strip draw a limit: "ring" or "bar" (a slim meter).
        self.gauge = "bar" if settings.get("gauge") == "bar" else "ring"
        # Set when the layout changes: the next build plays the intro.
        self.intro = True
        self.update = {"busy": "", "version": "", "commit": "", "behind": 0, "error": "", "checked": False}
        self.proc = None
        self.update_proc = None
        # API keys of OpenRouter / Z.ai, from scripts/keys.ts: {id: {name, url, source, saved}}.
        self.keys = {}
        self.keys_proc = None
        # Providers switched off: not fetched and not shown. At the first start only the ones set up on this machine
        # are on; "seen" remembers which were found, so one installed later turns on by itself and one switched off
        # stays off.
        self.hidden = [p for p in settings.get("hiddenProviders") or [] if isinstance(p, str)]
        seen = settings.get("seenProviders")
        self.seen = [p for p in seen if isinstance(p, str)] if isinstance(seen, list) else None
        # Providers this widget offered at the last detection: one added by an update starts off unless found here.
        known = settings.get("knownProviders")
        self.known = known if isinstance(known, list) else (self.seen or []) + self.hidden
        self.detect_proc = None
        # Asked for while a refresh was running (a provider switched back on, say): fetch again when it ends.
        self.refresh_pending = False
        # The last good result is cached on disk, so a restart (or a rate-limited first fetch) still shows numbers.
        cache = read_json(CACHE_FILE, {})
        if isinstance(cache, dict) and isinstance(cache.get("data"), list):
            self.data = cache["data"]
            self.updated_at = cache.get("updatedAt")

    def set_display(self, v):
        self.display = v
        save_setting("display", v)
        self.changed()

    def toggle_display(self):
        self.set_display("remaining" if self.display == "used" else "used")

    def set_layout(self, v):
        self.layout = v
        self.intro = True
        save_setting("layout", v)
        self.changed()

    def set_gauge(self, v):
        self.gauge = v
        self.intro = True
        save_setting("gauge", v)
        self.changed()

    def run_script(self, name, args, timeout, done, env=None):
        """Runs scripts/<name> with node and hands its stdout to `done`; None when it can't start."""
        script = os.path.join(ROOT, "scripts", name)
        flags = ["--experimental-strip-types", "--no-warnings", script] + args
        node = find_node()
        argv = [node] + flags if node else ["/bin/bash", "-lc", 'exec node "$@"', "node"] + flags
        launcher = Gio.SubprocessLauncher.new(Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        launcher.set_cwd(ROOT)
        for k, v in (env or {}).items():
            launcher.setenv(k, v, True)
        try:
            p = launcher.spawnv(argv)
        except GLib.Error:
            return None
        state = {"timed_out": False}

        def kill():
            state["timed_out"] = True
            p.force_exit()
            return False

        timer = GLib.timeout_add_seconds(timeout, kill)

        def finished(proc, res):
            if not state["timed_out"]:
                GLib.source_remove(timer)
            try:
                _, out, _ = proc.communicate_utf8_finish(res)
            except GLib.Error:
                out = ""
            done(out or "", state["timed_out"])

        p.communicate_utf8_async(None, None, finished)
        return p

    def run_keys(self, args, key=None, done=None):
        """
        scripts/keys.ts: no args reads which keys are found on this machine; "set <id>" checks the key with the
        service and keeps it; "remove <id>" forgets it. The key goes in an env var, never on the command line.
        `done` gets the error text, "" when none. False only when one is still running.
        """
        if self.keys_proc is not None:
            return False

        def finished(raw, timed_out):
            self.keys_proc = None
            error = "timed out" if timed_out else ""
            try:
                r = json.loads(raw)
                self.keys = {k["id"]: k for k in r.get("keys", [])}
                error = r.get("error") or ""
            except (ValueError, TypeError, KeyError):
                error = error or "couldn't read the keys"
            if done:
                done(error)
            self.changed()

        self.keys_proc = self.run_script("keys.ts", args, 40, finished, {"OPENUSAGE_KEY": key} if key else None)
        if self.keys_proc is None and done:
            done("node not found")
        return True

    def refresh(self):
        # While the providers are being detected the switches aren't settled yet; detection refreshes when done.
        if self.detect_proc is not None:
            return
        if self.proc is not None:
            self.refresh_pending = True
            return
        ids = [p for p in PROVIDER_NAMES if p not in self.hidden]
        # Nothing switched on: no ids would mean "whatever is set up" to the script, so don't ask at all.
        if not ids:
            self.data = []
            self.changed()
            return
        self.proc = self.run_script("usage-json.ts", ids, 60, self._complete)
        if self.proc is None:
            self.last_error = "node not found"
        else:
            self.refreshing = True
        self.changed()

    def detect(self):
        """Asks which providers are set up on this machine (local files only, no network), then refreshes."""
        if self.detect_proc is not None:
            return

        def done(raw, _timed_out):
            self.detect_proc = None
            self.refreshing = False
            try:
                found = json.loads(raw)
                assert isinstance(found, list)
            except (ValueError, AssertionError):
                # A run that failed (or printed nothing) found nothing out: leave the switches as they are.
                found = None
            if found is not None:
                every = list(PROVIDER_NAMES)
                if self.seen is None:
                    self.hidden = [p for p in every if p not in found]
                    self.seen = list(found)
                else:
                    new = [p for p in found if p not in self.seen]
                    unknown = [p for p in every if p not in self.known and p not in found]
                    self.hidden = [p for p in self.hidden if p not in new]
                    self.hidden += [p for p in unknown if p not in self.hidden]
                    self.seen += new
                self.known = every
                save_setting("hiddenProviders", self.hidden)
                save_setting("seenProviders", self.seen)
                save_setting("knownProviders", self.known)
            self.refresh()

        self.detect_proc = self.run_script("usage-json.ts", ["--detect"], 30, done)
        if self.detect_proc is None:
            self.refresh()
        else:
            self.refreshing = True
            self.changed()

    def set_provider(self, pid, on):
        """Switches a provider on or off; one switched back on has nothing cached, so it is fetched."""
        self.hidden = [p for p in self.hidden if p != pid] + ([] if on else [pid])
        save_setting("hiddenProviders", self.hidden)
        self.changed()
        if on:
            self.refresh()

    def providers_on(self):
        return [p for p in PROVIDER_NAMES if p not in self.hidden]

    def _complete(self, raw, timed_out):
        self.proc = None
        self.refreshing = False
        if self.refresh_pending:
            self.refresh_pending = False
            GLib.idle_add(lambda: self.refresh() and False)
        try:
            fresh = json.loads(raw)
            assert isinstance(fresh, list)
        except (ValueError, AssertionError):
            self.last_error = "timed out" if timed_out else "refresh failed"
            self.changed()
            return
        # A transient provider failure keeps the last good numbers, flagged as stale.
        prev = {}
        for u in self.data:
            prev.setdefault(uid(u), u)
        merged = []
        for u in fresh:
            old = prev.get(uid(u))
            if u.get("error") and old and old.get("windows"):
                merged.append({**old, "error": u["error"]})
            else:
                merged.append(u)
        self.data = merged
        self.updated_at = time.time() * 1000
        self.last_error = ""
        write_json(CACHE_FILE, {"updatedAt": self.updated_at, "data": self.data})
        self.changed()

    def run_update(self, action, applied=None):
        """"check" asks how far behind the remote this copy is; "apply" fast-forwards it."""
        if self.update_proc is not None:
            return

        def done(raw, _timed_out):
            self.update_proc = None
            self.update["busy"] = ""
            try:
                r = json.loads(raw)
                assert isinstance(r, dict)
            except (ValueError, AssertionError):
                self.update["error"] = "update check failed"
                self.changed()
                return
            self.update["version"] = r.get("version") or ""
            self.update["commit"] = r.get("commit") or ""
            self.update["error"] = r.get("error") or ""
            if isinstance(r.get("behind"), int):
                self.update["behind"] = r["behind"]
            self.update["checked"] = True
            self.changed()
            if action == "apply" and r.get("updated") and not r.get("error") and applied:
                applied()

        self.update["busy"] = action
        self.update_proc = self.run_script("update.ts", [action], 180, done)
        if self.update_proc is None:
            self.update["busy"] = ""
            self.update["error"] = "node not found"
        self.changed()

    def shown(self):
        """
        In compact mode a provider with no account at all (never signed in, no key, nothing to show) gets no card;
        the normal layout keeps it, with the hint on how to sign in.
        """
        on = [u for u in self.data if u.get("id") not in self.hidden]
        if self.layout == "normal":
            return on
        return [
            u
            for u in on
            if u.get("account") or u.get("windows") or u.get("extras") or not u.get("error")
        ]

    def tray_text(self):
        parts = [
            f"{u['name']} {round(max(w['usedPct'] for w in u['windows']))}%" for u in self.data
            if u.get("windows") and u.get("id") not in self.hidden
        ]
        return "OpenUsage - " + " | ".join(parts) if parts else "OpenUsage"


# ---- drawing -----------------------------------------------------------------------------


# Where each meter was last drawn, so a rebuilt one moves from there.
meter_state = {}


class Meter(Gtk.DrawingArea):
    """A rounded track whose fill slides to its value in a gradient of its color, and breathes a glow from 80%."""

    def __init__(self, used, color, key=None, width=-1, height=4, delay=0, intro=False, display="used"):
        super().__init__()
        self.used, self.color, self.h = used, color, height
        self.hot = used >= 80
        pad = 3 if self.hot else 0
        self.pad = pad
        self.set_size_request(width, height + 2 * pad)
        self.set_valign(Gtk.Align.CENTER)
        shown = used if display == "used" else 100 - used
        target = (100 if used >= 100 else max(0, min(100, shown))) / 100
        self.start = 0 if intro or key is None else meter_state.get(key, 0)
        if key is not None:
            meter_state[key] = target
        self.target = target
        self.value = self.start
        self.t0 = time.monotonic()
        self.connect("draw", self.draw)
        if self.start != target:
            self.value = self.start
            animate(self, 750, self.step, delay=delay)
        if self.hot:
            self.add_tick_callback(lambda w, clock: (w.queue_draw(), True)[1])

    def step(self, k):
        self.value = self.start + (self.target - self.start) * ease_out(k, 4)
        self.queue_draw()

    def capsule(self, cr, x, y, width, h):
        r = h / 2
        cr.new_sub_path()
        cr.arc(x + r, y + r, r, math.pi / 2, 3 * math.pi / 2)
        cr.arc(x + max(r, width - r), y + r, r, -math.pi / 2, math.pi / 2)
        cr.close_path()

    def draw(self, _w, cr):
        w = self.get_allocated_width() - 2 * self.pad
        h, x, y = self.h, self.pad, self.pad
        cr.set_source_rgb(*rgb(C["track"]))
        self.capsule(cr, x, y, w, h)
        cr.fill()
        fw = w * self.value
        if fw <= 0:
            return
        fw = max(h, fw)
        r, g, b = rgb(self.color)
        if self.hot:
            a = 0.12 + 0.3 * pulse(time.monotonic() - self.t0)
            for grow in (3, 1.5):
                cr.set_source_rgba(r, g, b, a / 2)
                self.capsule(cr, x - grow, y - grow, fw + 2 * grow, h + 2 * grow)
                cr.fill()
        if cairo is None:
            cr.set_source_rgb(r, g, b)
        else:
            grad = cairo.LinearGradient(x, 0, x + fw, 0)
            grad.add_color_stop_rgba(0, r, g, b, 0.55)
            grad.add_color_stop_rgba(1, r, g, b, 1)
            cr.set_source(grad)
        self.capsule(cr, x, y, fw, h)
        cr.fill()


# Where each ring was last drawn, so a rebuilt ring moves from there to its new value.
ring_state = {}


class Ring(Gtk.DrawingArea):
    """Outer arc = weekly (or the billing cycle), inner arc = 5 hours. The numbers sit beside it, not inside."""

    def __init__(self, u, display, size=42, t=4, mark=None):
        super().__init__()
        self.SIZE, self.T = size, t
        # The strip puts the provider's mark in the middle.
        self.mark = logo_surface(u["id"], mark, round(size * 0.4)) if mark else None
        self.glyph = (ICONS.get(u["id"], ""), mark) if mark and self.mark is None else None
        self.set_size_request(size + 8, size + 8)
        self.set_valign(Gtk.Align.CENTER)
        self.key = uid(u)
        self.short, self.long = slots(u)
        # A used-up limit is always a full ring (in red), whether numbers show used or left.
        target = lambda w: 0 if w is None else (100 if w["usedPct"] >= 100 else max(0, min(100, shown_pct(w, display))))
        self.target = (target(self.long) / 100, target(self.short) / 100)
        self.start = ring_state.get(self.key, (0, 0))
        self.progress = self.start
        ring_state[self.key] = self.target
        self.hot = any(w is not None and w["usedPct"] >= 80 for w in (self.short, self.long))
        self.born = time.monotonic()
        self.connect("draw", self.draw)
        if self.hot:
            self.add_tick_callback(lambda w, clock: (w.queue_draw(), True)[1])
        if self.start != self.target:
            self.t0 = time.monotonic()
            GLib.timeout_add(16, self.tick)

    def tick(self):
        k = min(1, (time.monotonic() - self.t0) / 0.55)
        e = 1 - (1 - k) ** 3
        self.progress = tuple(a + (b - a) * e for a, b in zip(self.start, self.target))
        self.queue_draw()
        return k < 1

    def draw(self, _w, cr):
        s, t = self.SIZE, self.T
        c = s / 2
        cr.translate(4, 4)
        both = self.short is not None and self.long is not None
        if self.hot:
            # A soft halo that breathes, in the warning color.
            r, g, b = rgb(C["error"])
            a = 0.1 + 0.3 * pulse(time.monotonic() - self.born)
            for width in (t + 7, t + 3):
                cr.set_source_rgba(r, g, b, a / 2)
                cr.set_line_width(width)
                cr.arc(c, c, (s - t) / 2, 0, 2 * math.pi)
                cr.stroke()
        inner = s - 2 * (t + 3)
        cr.set_line_width(t)

        def circle(d, color):
            cr.set_source_rgb(*rgb(color))
            cr.arc(c, c, (d - t) / 2, 0, 2 * math.pi)
            cr.stroke()

        def arc(d, p, color):
            # Under 1% a round-capped arc is just a dot, which reads as noise.
            if p < 0.01:
                return
            cr.set_source_rgb(*rgb(color))
            cr.set_line_cap(1)  # round
            cr.arc(c, c, (d - t) / 2, -math.pi / 2, -math.pi / 2 + 2 * math.pi * p)
            cr.stroke()
            cr.new_path()

        circle(s, C["track"])
        if both:
            circle(inner, C["track"])
        if self.long is not None:
            arc(s, self.progress[0], level(self.long["usedPct"]) or C["muted"])
        if self.short is not None:
            arc(inner if both else s, self.progress[1], level(self.short["usedPct"]) or C["text"])
        if self.mark is not None and (self.short is not None or self.long is not None):
            ms = round(s * 0.4)
            cr.set_source_surface(self.mark, c - ms / 2, c - ms / 2)
            cr.paint()
        elif self.glyph and (self.short is not None or self.long is not None):
            layout = self.create_pango_layout("")
            layout.set_markup(span(self.glyph[0], 10, self.glyph[1]))
            lw, lh = layout.get_pixel_size()
            cr.move_to(c - lw / 2, c - lh / 2)
            PangoCairo.show_layout(cr, layout)
        if self.short is None and self.long is None:
            layout = self.create_pango_layout("")
            layout.set_markup(span("!", 13, C["warn"], "bold"))
            lw, lh = layout.get_pixel_size()
            cr.move_to(c - lw / 2, c - lh / 2)
            PangoCairo.show_layout(cr, layout)


# ---- widgets -------------------------------------------------------------------------------


def hbox(spacing=0, *children):
    b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)
    for ch in children:
        b.pack_start(ch, False, False, 0)
    return b


def vbox(spacing=0):
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)


def styled(widget, *classes):
    for c in classes:
        widget.get_style_context().add_class(c)
    return widget


def margins(w, top=0, right=0, bottom=0, left=0):
    w.set_margin_top(top)
    w.set_margin_end(right)
    w.set_margin_bottom(bottom)
    w.set_margin_start(left)
    return w


def divider():
    return styled(Gtk.Box(), "divider")


def header_button(text, tip, action):
    b = styled(Gtk.Button(), "hbtn")
    b.add(label(span(text, 12)))
    b.set_tooltip_text(tip)
    b.set_relief(Gtk.ReliefStyle.NONE)
    b.set_can_focus(False)
    b.connect("clicked", lambda *_: action())
    return b


def with_dot(widget, show):
    """A small orange dot on the corner: a new version is waiting."""
    if not show:
        return widget
    o = Gtk.Overlay()
    o.add(widget)
    dot = Gtk.DrawingArea()
    dot.set_size_request(6, 6)
    dot.set_halign(Gtk.Align.END)
    dot.set_valign(Gtk.Align.START)
    margins(dot, top=1, right=2)

    def draw(_w, cr):
        cr.set_source_rgb(*rgb(C["warn"]))
        cr.arc(3, 3, 3, 0, 2 * math.pi)
        cr.fill()

    dot.connect("draw", draw)
    o.add_overlay(dot)
    o.set_overlay_pass_through(dot, True)
    return o


def hover_box(child, tooltip=None):
    """An EventBox that lights up under the pointer."""
    eb = Gtk.EventBox()
    eb.set_visible_window(True)
    eb.add(child)
    eb.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
    styled(eb, "row")

    def enter(*_):
        eb.get_style_context().add_class("hover")

    def leave(_w, ev):
        if ev.detail != Gdk.NotifyType.INFERIOR:
            eb.get_style_context().remove_class("hover")

    eb.connect("enter-notify-event", enter)
    eb.connect("leave-notify-event", leave)
    if tooltip:
        eb.set_tooltip_text(tooltip)
    return eb


def hover_card(outer):
    """Cards: the border lights up under the pointer."""
    eb = Gtk.EventBox()
    eb.set_visible_window(False)
    eb.add(outer)
    eb.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
    eb.connect("enter-notify-event", lambda *_: outer.get_style_context().add_class("hover"))
    eb.connect(
        "leave-notify-event",
        lambda _w, ev: ev.detail != Gdk.NotifyType.INFERIOR and outer.get_style_context().remove_class("hover"),
    )
    return eb


def card(u, display, index=0, intro=False):
    has_data = bool(u.get("windows") or u.get("extras"))
    box = margins(vbox(), 9, 11, 10, 11)
    top = hbox(0)
    title = logo_title(u["id"], u["name"])
    top.pack_start(title, True, True, 0)
    if u.get("plan"):
        badge = styled(hbox(0, label(span(u["plan"].upper(), 10, C["muted"], "bold"))), "badge")
        badge.set_valign(Gtk.Align.CENTER)
        top.pack_end(badge, False, False, 0)
    box.pack_start(top, False, False, 0)
    if u.get("account"):
        box.pack_start(
            margins(label(span(u["account"], 11.5, C["muted"]), ellipsize=True, tooltip=u["account"]), top=1),
            False, False, 0,
        )
    if u.get("error"):
        text = f"stale - {u['error']}" if has_data else u["error"]
        box.pack_start(margins(label(span(text, 12, C["warn"] if has_data else C["muted"]), wrap=True), top=6), False, False, 0)
    for i, w in enumerate(u.get("windows") or []):
        pct = shown_pct(w, display)
        lv = level(w["usedPct"])
        reset = format_reset(w.get("resetsAt"))
        row = hbox(8)
        row.pack_start(label(span(w["label"]) + (span(f"  {reset}", 12, C["muted"]) if reset else ""), ellipsize=True), True, True, 0)
        row.pack_end(label(span(f"{round(pct)}%", 13, lv or C["text"], "bold"), xalign=1), False, False, 0)
        box.pack_start(margins(row, top=9 if i == 0 else 8), False, False, 0)
        meter = Meter(w["usedPct"], lv or C["muted"], f"{uid(u)}|{w['label']}", delay=120 + 70 * index, intro=intro, display=display)
        box.pack_start(margins(meter, top=2), False, False, 0)
    for i, x in enumerate(u.get("extras") or []):
        row = hbox(8)
        row.pack_start(label(span(x["label"], 12.5, C["muted"]), ellipsize=True), True, True, 0)
        row.pack_end(label(span(x["value"], 12.5), xalign=1), False, False, 0)
        box.pack_start(margins(row, top=9 if not u.get("windows") and i == 0 else 8), False, False, 0)
    outer = styled(vbox(), "card")
    outer.pack_start(box, True, True, 0)
    return hover_card(outer)


def account_row(u, display):
    """One line per account: ring, name with plan and next reset, then the 5h / weekly numbers on the right."""
    short, long = slots(u)
    ws = [w for w in (short, long) if w is not None]
    plan = (u.get("plan") or "").upper()
    name = short_account(u)
    # Without a known account (an API key, say) there is no name: the plan, or just the next line, leads.
    title = name or plan
    if u.get("error"):
        sub, sub_color = (u["error"], C["muted"]) if not ws else ("stale", C["warn"])
    else:
        parts = []
        if name and plan:
            parts.append(plan)
        first = short or long
        if first is not None and first.get("resetsAt") is not None:
            parts.append(f"↻ {format_reset_short(first['resetsAt'])}")
        sub, sub_color = "  ·  ".join(parts), C["muted"]

    row = margins(hbox(0), 1, 8, 1, 2)
    row.pack_start(Ring(u, display), False, False, 0)
    text = margins(vbox(1), left=8, right=10)
    text.set_valign(Gtk.Align.CENTER)
    if title:
        text.pack_start(label(span(title, 13), ellipsize=True), False, False, 0)
    if sub:
        text.pack_start(label(span(sub, 12 if not title else 11.5, sub_color), ellipsize=bool(title), wrap=not title), False, False, 0)
    row.pack_start(text, True, True, 0)
    # Numbers in a column of their own, so the percentages line up.
    nums = vbox(2)
    nums.set_valign(Gtk.Align.CENTER)
    for w in ws:
        line = hbox(8)
        line.pack_start(label(span(slot_name(w), 11.5, C["muted"]), xalign=1), False, False, 0)
        pct = label(span(f"{round(shown_pct(w, display))}%", 13, level(w["usedPct"]) or C["text"], "bold"), xalign=1)
        pct.set_size_request(34, -1)
        line.pack_start(pct, False, False, 0)
        line.set_halign(Gtk.Align.END)
        nums.pack_start(line, False, False, 0)
    row.pack_end(nums, False, False, 0)
    return hover_box(row, tip_text(u, display))


def short_slot(w):
    """A few letters, so meters line up: "Credits" -> "cr", "Daily" -> "day"."""
    n = slot_name(w)
    return "cr" if n.startswith("Credit") else "day" if n.startswith("Daily") else n[:3].lower() if len(n) > 3 else n


def meter_line(u, w, display, accent, length, index, intro):
    """5h ▬▬▬▬▭▭ 72%"""
    lv = level(w["usedPct"])
    line = hbox(0)
    name = label(span(short_slot(w), 10, C["muted"]))
    name.set_size_request(16, -1)
    line.pack_start(name, False, False, 0)
    meter = Meter(w["usedPct"], lv or accent, f"{uid(u)}|{w['label']}|m", length, 5, 120 + 70 * index, intro, display)
    line.pack_start(margins(meter, left=3, right=5), False, False, 0)
    pct = label(span(f"{round(shown_pct(w, display))}%", 11, lv or C["text"], "bold"))
    pct.set_size_request(27, -1)
    line.pack_start(pct, False, False, 0)
    return line


def account_meter_row(u, display, accent, index, intro):
    """Compact with bars: one short line per account, its name and a meter per limit."""
    short, long = slots(u)
    ws = [w for w in (short, long) if w is not None]
    extras = u.get("extras") or []
    title = short_account(u)
    if not title:
        # No account to name (an API key): the balance says more than the plan already in the header.
        bal = next((x for x in extras if "Balance" in x["label"]), None)
        title = f"{bal['value']} balance" if bal and ws else re.sub(r" \(.*\)$", "", u["name"])
    row = margins(hbox(8), 3, 6, 3, 6)
    row.pack_start(label(span(title, 12), ellipsize=True), True, True, 0)
    right = hbox(6)
    right.set_valign(Gtk.Align.CENTER)
    if ws:
        for w in ws:
            right.pack_start(meter_line(u, w, display, accent, 112 if len(ws) == 1 else 36, index, intro), False, False, 0)
        if u.get("error"):
            right.set_opacity(0.55)
    elif extras:
        right.pack_start(label(span(extras[0]["label"].lower(), 11, C["muted"])), False, False, 0)
        right.pack_start(label(span(extras[0]["value"], 12, weight="bold")), False, False, 0)
    else:
        right.pack_start(label(span(u.get("error") or "no data", 11, C["muted"]), ellipsize=True), False, False, 0)
    row.pack_end(right, False, False, 0)
    return hover_box(row, tip_text(u, display))


def compact_card(pid, accounts, display, gauge="ring", index=0, intro=False):
    first = accounts[0]
    name = re.sub(r" \(.*\)$", "", first["name"])
    accent = C.get(pid, C["text"])
    box = margins(vbox(), 10 if gauge == "ring" else 8, 6, 6, 6)
    top = margins(hbox(0), left=6, right=6)
    top.pack_start(logo_title(pid, name), True, True, 0)
    right = f"{len(accounts)} accounts" if len(accounts) > 1 else (first.get("plan") or "").upper()
    top.pack_end(label(span(right, 10.5, C["muted"], "bold"), xalign=1), False, False, 0)
    box.pack_start(top, False, False, 0)
    rows = margins(vbox(), top=6 if gauge == "ring" else 4)
    for u in accounts:
        if gauge == "bar":
            rows.pack_start(account_meter_row(u, display, accent, index, intro), False, False, 0)
        else:
            rows.pack_start(account_row(u, display), False, False, 0)
    box.pack_start(rows, False, False, 0)
    outer = styled(vbox(), "ccard")
    outer.pack_start(box, True, True, 0)
    return hover_card(outer)


def strip_chip(u, display, gauge, index, intro):
    """One account in the strip: a ring pair around the mark (or the mark and a meter per limit) and its numbers."""
    short, long = slots(u)
    ws = [w for w in (short, long) if w is not None]
    extras = u.get("extras") or []
    accent = C.get(u["id"], C["text"])
    content = hbox(7)
    if gauge == "bar":
        mark = styled(Gtk.Box(), "mark")
        mark.set_size_request(26, 26)
        mark.set_valign(Gtk.Align.CENTER)
        lg = logo(u["id"], accent, 14)
        lg.set_halign(Gtk.Align.CENTER)
        mark.pack_start(lg, True, True, 0)
        content.pack_start(mark, False, False, 0)
        col = vbox(0)
        col.set_valign(Gtk.Align.CENTER)
        if ws:
            for w in ws:
                col.pack_start(meter_line(u, w, display, accent, 46, index, intro), False, False, 0)
            if len(ws) == 1:
                who = short_account(u) or (f"{extras[0]['value']} {extras[0]['label'].lower()}" if extras else "")
                if who:
                    col.pack_start(label(span(who, 10, C["muted"])), False, False, 0)
        elif extras:
            col.pack_start(label(span(extras[0]["value"], 12.5, weight="bold")), False, False, 0)
            col.pack_start(label(span(extras[0]["label"].lower(), 10, C["muted"])), False, False, 0)
        else:
            col.pack_start(label(span(re.sub(r" \(.*\)$", "", u["name"]), 12, weight="bold")), False, False, 0)
            col.pack_start(label(span("error" if u.get("error") else "no data", 10, C["warn"] if u.get("error") else C["muted"])), False, False, 0)
        content.pack_start(col, False, False, 0)
    else:
        content.pack_start(Ring(u, display, 32, 3, accent), False, False, 0)
        col = vbox(0)
        col.set_valign(Gtk.Align.CENTER)
        main = short or long
        other = long if short is not None and long is not None else None
        if main is not None:
            lv = level(main["usedPct"])
            col.pack_start(
                label(span(f"{round(shown_pct(main, display))}%", 13, lv or C["text"], "bold") + span(f" {slot_name(main)}", 10, C["muted"])),
                False, False, 0,
            )
            if other is not None:
                sub, color = f"{slot_name(other)} {round(shown_pct(other, display))}%", level(other["usedPct"]) or C["muted"]
            else:
                sub, color = short_account(u), C["muted"]
        elif extras:
            col.pack_start(label(span(extras[0]["value"], 13, weight="bold")), False, False, 0)
            sub, color = extras[0]["label"].lower(), C["muted"]
        else:
            col.pack_start(label(span(re.sub(r" \(.*\)$", "", u["name"]), 12, weight="bold")), False, False, 0)
            sub, color = "no data", C["muted"]
        if sub:
            col.pack_start(label(span(sub, 10, color)), False, False, 0)
        content.pack_start(col, False, False, 0)
    chip = styled(hover_box(margins(content, 1, 10 if gauge == "ring" else 6, 1, 1), tip_text(u, display)), "chip")
    # Numbers kept from a failed refresh fade back a little.
    target = 0.55 if u.get("error") and ws else 1.0
    if intro:
        fade_in(chip, index, target=target)
    else:
        chip.set_opacity(target)
    return chip


class Spin(Gtk.DrawingArea):
    """A glyph that turns while `spinning` (the refresh arrow during a refresh)."""

    def __init__(self, text, size, spinning):
        super().__init__()
        self.text, self.size, self.spinning = text, size, spinning
        self.t0 = time.monotonic()
        self.set_size_request(round(size * 1.3), round(size * 1.3))
        self.connect("draw", self.draw)
        if spinning:
            self.add_tick_callback(lambda w, clock: (w.queue_draw(), True)[1])

    def draw(self, _w, cr):
        w, h = self.get_allocated_width(), self.get_allocated_height()
        layout = self.create_pango_layout("")
        color = self.get_style_context().get_color(self.get_state_flags())
        layout.set_markup(span(self.text, self.size))
        lw, lh = layout.get_pixel_size()
        cr.translate(w / 2, h / 2)
        if self.spinning:
            cr.rotate(((time.monotonic() - self.t0) / 0.9 % 1) * 2 * math.pi)
        cr.set_source_rgba(color.red, color.green, color.blue, color.alpha)
        cr.move_to(-lw / 2, -lh / 2)
        PangoCairo.show_layout(cr, layout)


def spin_button(text, tip, action, spinning):
    b = styled(Gtk.Button(), "hbtn")
    b.add(Spin(text, 12, spinning))
    b.set_tooltip_text(tip)
    b.set_relief(Gtk.ReliefStyle.NONE)
    b.set_can_focus(False)
    b.connect("clicked", lambda *_: action())
    return b


def segmented(options, value, pick):
    """Pill-shaped choice, like the Windows settings: the picked option is filled."""
    box = styled(hbox(0), "seg")
    for v, text in options:
        b = styled(Gtk.Button(label=text), "segbtn")
        if v == value:
            styled(b, "on")
        b.set_can_focus(False)
        b.get_child().set_xalign(0.5)
        b.connect("clicked", lambda _b, v=v: choose(_b, v))
        box.pack_start(b, False, False, 0)
    box.set_valign(Gtk.Align.CENTER)

    def choose(btn, v):
        # The highlight moves first (a CSS transition), then the choice applies.
        for ch in box.get_children():
            ch.get_style_context().remove_class("on")
        btn.get_style_context().add_class("on")
        GLib.timeout_add(180, lambda: pick(v) and False)
    return box


def dialog_button(text, action, primary=False, enabled=True):
    b = styled(Gtk.Button(label=text), "dbtn")
    if primary:
        styled(b, "primary")
    b.set_sensitive(enabled)
    b.set_can_focus(False)
    b.connect("clicked", lambda *_: action())
    return b


# ---- floating window ---------------------------------------------------------------------


class Floating(Gtk.Window):
    """Borderless, rounded, sized to its content, dragged by its header."""

    def __init__(self, app, width):
        super().__init__(application=app)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_app_paintable(True)
        styled(self, "ou")
        visual = self.get_screen().get_rgba_visual()
        if visual is not None and self.get_screen().is_composited():
            self.set_visual(visual)
        if os.path.isfile(ICON_PATH):
            self.set_icon_from_file(ICON_PATH)
        self.frame = styled(vbox(), "frame")
        self.frame.set_size_request(width, -1)
        self.width = width
        self.strip = False
        # While a refresh runs, a soft light sweeps across the frame.
        self.shine = Gtk.DrawingArea()
        self.shine.connect("draw", self.draw_shine)
        self.shining, self.shine_alpha, self.shine_t0, self.shine_tick = False, 0.0, time.monotonic(), None
        overlay = Gtk.Overlay()
        overlay.add(self.frame)
        overlay.add_overlay(self.shine)
        overlay.set_overlay_pass_through(self.shine, True)
        self.add(overlay)

    def set_strip(self, on):
        self.strip = on
        ctx = self.frame.get_style_context()
        (ctx.add_class if on else ctx.remove_class)("strip")
        self.frame.set_size_request(-1 if on else self.width, -1)

    def set_shimmer(self, on):
        if on == self.shining:
            return
        self.shining = on
        if on:
            self.shine_t0 = time.monotonic()
        if self.shine_tick is None:
            self.shine_tick = self.shine.add_tick_callback(self.shine_step)

    def shine_step(self, w, _clock):
        self.shine_alpha += ((1 if self.shining else 0) - self.shine_alpha) * 0.12
        w.queue_draw()
        if not self.shining and self.shine_alpha < 0.02:
            self.shine_alpha, self.shine_tick = 0.0, None
            w.queue_draw()
            return False
        return True

    def draw_shine(self, w, cr):
        if self.shine_alpha <= 0 or cairo is None:
            return
        W, H = w.get_allocated_width(), w.get_allocated_height()
        r = min(23 if self.strip else 12, H / 2)
        cr.new_sub_path()
        cr.arc(W - r, r, r, -math.pi / 2, 0)
        cr.arc(W - r, H - r, r, 0, math.pi / 2)
        cr.arc(r, H - r, r, math.pi / 2, math.pi)
        cr.arc(r, r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()
        cr.clip()
        k = ((time.monotonic() - self.shine_t0) / 1.3) % 1
        k = 0.5 - 0.5 * math.cos(math.pi * k)
        mid = W * (-0.2 + 1.4 * k)
        band = max(60, W * 0.25)
        red, green, blue = rgb(C["text"])
        grad = cairo.LinearGradient(mid - band, 0 if self.strip else -H * 0.2, mid + band, 0 if self.strip else H * 0.2)
        grad.add_color_stop_rgba(0, red, green, blue, 0)
        grad.add_color_stop_rgba(0.5, red, green, blue, 0.11 * self.shine_alpha)
        grad.add_color_stop_rgba(1, red, green, blue, 0)
        cr.set_source(grad)
        cr.paint()

    def drag_area(self, child, menu=None):
        eb = Gtk.EventBox()
        eb.add(child)

        def press(_w, ev):
            if ev.button == 1 and ev.type == Gdk.EventType.BUTTON_PRESS:
                self.begin_move_drag(ev.button, int(ev.x_root), int(ev.y_root), ev.time)
            elif ev.button == 3 and menu:
                menu().popup_at_pointer(ev)
            return True

        eb.connect("button-press-event", press)
        return eb

    def set_content(self, widget):
        # On the right half of the screen the right edge stays put (the strip grows leftward); elsewhere the left one.
        anchor = None
        gw = self.get_window()
        if gw is not None:
            x, y = self.get_position()
            w, _ = self.get_size()
            area = Gdk.Display.get_default().get_monitor_at_window(gw).get_workarea()
            if x + w / 2 > area.x + area.width / 2:
                anchor = (x + w, y)
        for ch in self.frame.get_children():
            ch.destroy()
        self.frame.pack_start(widget, True, True, 0)
        self.frame.show_all()
        # Shrink back when the content gets shorter.
        self.resize(1, 1)
        if anchor is not None:
            nw = self.get_preferred_size()[1].width
            self.move(anchor[0] - nw, anchor[1])


# ---- accounts ------------------------------------------------------------------------------
# Each extra account lives in its own config folder in home (".claude-2", ".codex-work"...), which the
# providers find on their own. Adding one asks for a command name (e.g. "claude2") and opens a terminal on
# scripts/add-account.ts, which creates the folder and a claude2 command for it, then signs in.

ACCOUNT_KINDS = [
    {"id": "claude", "name": "Claude", "prefix": ".claude", "command": "claude"},
    {"id": "codex", "name": "Codex", "prefix": ".codex", "command": "codex"},
]


def account_dir(k, name):
    """"claude2" -> ~/.claude-2, "claude-work" -> ~/.claude-work, "work" -> ~/.claude-work."""
    suffix = name[len(k["command"]) :] if name.lower().startswith(k["command"]) else name
    suffix = suffix.lstrip("-_")
    return os.path.join(HOME, f"{k['prefix']}-{suffix}") if suffix else None


def command_exists(name):
    """Launchers get a bare PATH, so also look where installers usually put CLIs."""
    dirs = os.environ.get("PATH", "").split(":") + [
        os.path.join(HOME, ".local", "bin"),
        "/usr/local/bin",
        os.path.join(HOME, ".npm-global", "bin"),
    ]
    node = find_node()
    if node:
        dirs.append(os.path.dirname(node))
    return any(is_exe(os.path.join(d, name)) for d in dirs if d)


def account_name_problem(k, name):
    """Why a command name can't be used, or None when it can."""
    if not name:
        return "Type a name."
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name):
        return "Use only letters, digits, - and _."
    d = account_dir(k, name)
    if d is None:
        return f"Pick a name other than {k['command']}."
    if command_exists(name):
        return f"A command named {name} already exists."
    if os.path.exists(d):
        return f"The folder ~/{os.path.basename(d)} already exists."
    return None


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def terminal_argv(script):
    """A command line that opens `script` in the user's terminal, or None when there is none."""
    candidates = [
        (os.environ.get("TERMINAL"), ["-e", script]),
        ("x-terminal-emulator", ["-e", script]),
        ("gnome-terminal", ["--", script]),
        ("kgx", ["--", script]),
        ("ptyxis", ["--", script]),
        ("konsole", ["-e", script]),
        ("xfce4-terminal", ["-e", script]),
        ("mate-terminal", ["-e", script]),
        ("tilix", ["-e", script]),
        ("alacritty", ["-e", script]),
        ("kitty", [script]),
        ("foot", [script]),
        ("wezterm", ["start", "--", script]),
        ("xterm", ["-e", script]),
    ]
    for cmd, args in candidates:
        path = shutil.which(cmd) if cmd else None
        if path:
            return [path] + args
    return None


# ---- app ---------------------------------------------------------------------------------------


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.win = None

    def do_activate(self):
        # A second launch lands here instead of starting another copy.
        if self.win is not None:
            self.show_window()
            return
        self.hold()
        self.iface = interface_settings()
        self.css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), self.css, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self.load_theme()
        if self.iface is not None:
            self.iface.connect("changed", lambda _s, key: key in ("color-scheme", "gtk-theme") and self.load_theme(True))

        self.model = Model(self.changed)
        self.settings_win = None
        self.has_tray = False
        self.tray = None

        UI_SCALE[0] = max(1, Gdk.Display.get_default().get_monitor(0).get_scale_factor())
        self.win = Floating(self, 304)
        self.win.set_title("OpenUsage")
        # Strip: its buttons stay faint until the pointer comes over it.
        self.win.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.win.connect("enter-notify-event", lambda *_: self.fade_tools(1.0))
        self.win.connect("leave-notify-event", lambda _w, ev: ev.detail != Gdk.NotifyType.INFERIOR and self.fade_tools(0.35))
        self.win.stick()
        self.topmost = settings.get("topmost", True) is not False
        self.win.set_keep_above(self.topmost)
        self.win.connect("configure-event", self.moved)
        self.win.connect("delete-event", lambda *_: self.hide_window() or True)
        self.place()
        self.build()
        self.win.show_all()
        # The strip's width is only known now.
        right = settings.get("right")
        if isinstance(right, int) and isinstance(settings.get("y"), int):
            self.win.move(right - self.win.get_preferred_size()[1].width, settings["y"])
        self.setup_tray()

        GLib.timeout_add_seconds(REFRESH_MINUTES * 60, lambda: self.model.refresh() or True)
        # Look for a new version at start and once a day; the gear gets a dot when there is one.
        GLib.timeout_add_seconds(24 * 3600, lambda: self.model.run_update("check") or True)
        # Re-renders the "updated N min ago" label.
        GLib.timeout_add_seconds(30, self.tick)
        self.model.detect()
        self.model.run_update("check")

    # ---- theme and layout

    def load_theme(self, rebuild=False):
        apply_theme(is_dark(self.iface))
        self.css.load_from_data(css_text().encode())
        if rebuild:
            self.changed()

    def place(self):
        x, y = settings.get("x"), settings.get("y")
        if isinstance(x, int) and isinstance(y, int):
            self.win.move(x, y)
            return
        display = Gdk.Display.get_default()
        mon = display.get_primary_monitor() or display.get_monitor(0)
        area = mon.get_workarea()
        self.win.move(area.x + area.width - 330, area.y + 16)

    def moved(self, win, _ev):
        x, y = win.get_position()
        w, _ = win.get_size()
        # On the right half of the screen the right edge is what stays put, also across restarts.
        right = None
        if win.get_window() is not None:
            area = Gdk.Display.get_default().get_monitor_at_window(win.get_window()).get_workarea()
            right = x + w if x + w / 2 > area.x + area.width / 2 else None
        if (settings.get("x"), settings.get("y"), settings.get("right")) != (x, y, right):
            settings["x"], settings["y"], settings["right"] = x, y, right
            # Many configure events arrive during a drag: save once it settles.
            if getattr(self, "save_timer", None):
                GLib.source_remove(self.save_timer)
            self.save_timer = GLib.timeout_add(500, self.save_position)
        return False

    def save_position(self):
        self.save_timer = None
        write_json(SETTINGS_FILE, settings)
        return False

    def changed(self):
        if self.win is None:
            return
        self.build()
        if self.settings_win is not None:
            self.build_settings()
        self.update_tray()

    def tick(self):
        if hasattr(self, "footer"):
            self.footer.set_markup(self.footer_markup())
        return True

    def footer_markup(self):
        m = self.model
        return span("refreshing..." if m.refreshing else format_ago(m.updated_at), 11.5, C["muted"])

    def fade_tools(self, to):
        tools = getattr(self, "strip_tools", None)
        if tools is None or tools.get_parent() is None:
            return
        start = tools.get_opacity()
        animate(tools, 200 if to > start else 400, lambda k: tools.set_opacity(start + (to - start) * ease_out(k)))

    def build_strip(self):
        m = self.model
        row = margins(hbox(2), 4, 5, 4, 5)
        grip = margins(label(span("◷", 14, C["muted"])), left=7, right=5)
        grip.set_tooltip_text(f"OpenUsage - {m.last_error}" if m.last_error else f"OpenUsage - {format_ago(m.updated_at)}")
        row.pack_start(grip, False, False, 0)
        shown = m.shown()
        prev = None
        for i, u in enumerate(shown):
            # A hairline between providers; accounts of the same provider sit together.
            if prev is not None and prev != u["id"]:
                sep = styled(Gtk.Box(), "divider")
                sep.set_size_request(1, 20)
                sep.set_valign(Gtk.Align.CENTER)
                row.pack_start(margins(sep, left=3, right=3), False, False, 0)
            row.pack_start(strip_chip(u, m.display, m.gauge, i, m.intro), False, False, 0)
            prev = u["id"]
        if not shown:
            row.pack_start(margins(label(span("Loading..." if m.refreshing else "No data", 12, C["muted"])), left=4, right=8), False, False, 0)
        tools = hbox(0)
        tools.set_valign(Gtk.Align.CENTER)
        tools.pack_start(spin_button("⟳", "Refresh", m.refresh, m.refreshing), False, False, 0)
        tools.pack_start(with_dot(header_button("⚙", "Settings", self.show_settings), m.update["behind"] > 0), False, False, 0)
        tools.set_opacity(0.35)
        self.strip_tools = tools
        row.pack_start(margins(tools, left=2), False, False, 0)
        self.win.set_content(self.win.drag_area(row, self.make_menu))

    def build(self):
        m = self.model
        self.win.set_strip(m.layout == "bar")
        if m.layout == "bar":
            self.build_strip()
        else:
            self.build_panel()
        self.win.set_shimmer(m.refreshing)
        m.intro = False

    def build_panel(self):
        m = self.model
        root = margins(vbox(), 10, 14, 10, 14)

        head = hbox(2)
        head.pack_start(
            label(span("◷", 13, C["muted"], "bold") + span(" OpenUsage", 13, weight="bold")), True, True, 0
        )
        head.pack_start(with_dot(header_button("⚙", "Settings", self.show_settings), m.update["behind"] > 0), False, False, 0)
        head.pack_start(header_button("+", "Add account", self.show_add_menu), False, False, 0)
        head.pack_start(header_button("Used" if m.display == "used" else "Left", "Used / left", m.toggle_display), False, False, 0)
        head.pack_start(spin_button("⟳", "Refresh", m.refresh, m.refreshing), False, False, 0)
        hide_tip = "Hide (tray icon brings it back)" if self.has_tray else "Minimize"
        head.pack_start(header_button("✕", hide_tip, self.hide_window), False, False, 0)
        root.pack_start(margins(self.win.drag_area(head, self.make_menu), bottom=8), False, False, 0)
        root.pack_start(margins(divider(), bottom=8), False, False, 0)

        shown = m.shown()
        if not shown:
            msg = (
                "Loading..." if m.refreshing
                else "No AI tool found on this machine. Turn one on in settings (⚙)." if not m.providers_on()
                else "No data"
            )
            root.pack_start(label(span(msg, 13, C["muted"]), wrap=True), False, False, 0)
        cards = vbox(8)
        blocks = (
            [compact_card(pid, accounts, m.display, m.gauge, i, m.intro) for i, (pid, accounts) in enumerate(groups(shown))]
            if m.layout == "compact"
            else [card(u, m.display, i, m.intro) for i, u in enumerate(shown)]
        )
        for i, b in enumerate(blocks):
            cards.pack_start(b, False, False, 0)
            if m.intro:
                fade_in(b, i)
        root.pack_start(cards, False, False, 0)

        root.pack_start(margins(divider(), top=10, bottom=6), False, False, 0)
        foot = hbox(8)
        self.footer = label(self.footer_markup())
        foot.pack_start(self.footer, False, False, 0)
        foot.pack_end(label(span(m.last_error, 11.5, C["error"]), xalign=1, ellipsize=True), True, True, 0)
        root.pack_start(foot, False, False, 0)
        self.win.set_content(root)

    # ---- settings

    def show_settings(self):
        if self.settings_win is not None:
            self.settings_win.present()
            return
        w = Floating(self, 356)
        w.set_title("OpenUsage settings")
        w.set_keep_above(True)
        w.set_transient_for(self.win)
        w.set_skip_taskbar_hint(True)
        w.connect("delete-event", lambda *_: self.close_settings() or True)
        self.settings_win = w
        self.model.run_keys([])
        # Opening plays the rows in one after the other; rebuilds while it stays open don't.
        self.settings_intro = True
        self.build_settings()
        # Beside the widget: to its left when there is room, else to its right.
        x, y = self.win.get_position()
        ww, _ = self.win.get_size()
        sw = w.get_preferred_size()[1].width
        mon = Gdk.Display.get_default().get_monitor_at_window(self.win.get_window()) if self.win.get_window() else None
        left_edge = mon.get_workarea().x if mon else 0
        w.move(x - sw - 8 if x - sw - 8 >= left_edge else x + ww + 8, y)
        w.show_all()

    def close_settings(self):
        if self.settings_win is not None:
            self.settings_win.destroy()
            self.settings_win = None

    def build_settings(self):
        m, u = self.model, self.model.update
        if u["busy"] == "apply":
            status = ("Updating...", C["muted"])
        elif u["busy"] == "check":
            status = ("Checking for updates...", C["muted"])
        elif u["error"]:
            status = (f"Can't update: {u['error']}", C["error"])
        elif u["behind"] > 0:
            status = (f"Update available: {u['behind']} new change{'s' if u['behind'] > 1 else ''}", C["warn"])
        elif u["checked"]:
            status = ("Up to date", C["ok"])
        else:
            status = ("Not checked yet", C["muted"])

        root = margins(vbox(), 14, 18, 16, 18)
        head = hbox(0)
        head.pack_start(label(span("⚙", 14.5, C["muted"], "bold") + span("  Settings", 14.5, weight="bold")), True, True, 0)
        head.pack_end(header_button("✕", "Close", self.close_settings), False, False, 0)
        root.pack_start(margins(self.settings_win.drag_area(head), bottom=12), False, False, 0)

        def caption(text):
            return margins(label(span(text, 10.5, C["muted"], "bold")), bottom=8)

        def option(title, note, control):
            row = hbox(8)
            text = vbox(1)
            text.pack_start(label(span(title, 13)), False, False, 0)
            text.pack_start(label(span(note, 11, C["muted"])), False, False, 0)
            row.pack_start(text, True, True, 0)
            row.pack_end(control, False, False, 0)
            return row

        root.pack_start(caption("DISPLAY"), False, False, 0)
        root.pack_start(
            option("Numbers", "Default for every limit", segmented([("used", "Used"), ("remaining", "Left")], m.display, m.set_display)),
            False, False, 0,
        )
        notes = {"normal": "A card per account", "compact": "A line per account", "bar": "One slim strip"}
        root.pack_start(
            margins(option("Layout", notes[m.layout], segmented([("normal", "Normal"), ("compact", "Compact"), ("bar", "Strip")], m.layout, m.set_layout)), top=8),
            False, False, 0,
        )
        gauge_note = "For Compact and Strip" if m.layout == "normal" else "Slim meters" if m.gauge == "bar" else "Rings around the numbers"
        root.pack_start(
            margins(option("Gauges", gauge_note, segmented([("ring", "Rings"), ("bar", "Bars")], m.gauge, m.set_gauge)), top=8),
            False, False, 0,
        )
        root.pack_start(margins(divider(), top=16, bottom=14), False, False, 0)
        root.pack_start(caption("PROVIDERS"), False, False, 0)
        grid = Gtk.Grid(column_spacing=20, row_spacing=8, column_homogeneous=True)
        on_count = len(m.providers_on())
        for i, (pid, name) in enumerate(PROVIDER_NAMES.items()):
            on = pid not in m.hidden
            row = hbox(6)
            row.pack_start(logo_title(pid, name, 13, weight=None), True, True, 0)
            sw = Gtk.Switch(active=on, valign=Gtk.Align.CENTER, tooltip_text=f"Show {name}")
            # The last one left on can't be switched off, so the widget is never empty.
            sw.set_sensitive(not on or on_count > 1)
            # Switching rebuilds this dialog, so wait until the switch is done with its own signal.
            sw.connect("notify::active", lambda w, _p, pid=pid: GLib.idle_add(lambda on=w.get_active(): m.set_provider(pid, on) and False))
            row.pack_end(sw, False, False, 0)
            grid.attach(row, i % 2, i // 2, 1, 1)
        root.pack_start(grid, False, False, 0)
        root.pack_start(margins(divider(), top=14, bottom=14), False, False, 0)
        root.pack_start(caption("API KEYS"), False, False, 0)
        root.pack_start(
            margins(label(span("Found by itself when OpenCode, Kilo, Crush or Claude Code already use one; otherwise add it here.", 11.5, C["muted"]), wrap=True), bottom=10),
            False, False, 0,
        )
        for pid in KEYED_PROVIDERS:
            k = m.keys.get(pid)
            row = hbox(6)
            text = vbox(1)
            text.pack_start(logo_title(pid, PROVIDER_NAMES[pid], 13, weight=None), False, False, 0)
            text.pack_start(label(span(key_status(k), 11, C["muted"])), False, False, 0)
            row.pack_start(text, True, True, 0)
            row.pack_end(dialog_button("Change" if k and k.get("source") else "Add key", lambda pid=pid: self.ask_key(pid), enabled=bool(k)), False, False, 0)
            if k and k.get("saved"):
                row.pack_end(dialog_button("Remove", lambda pid=pid: m.run_keys(["remove", pid], done=lambda _e: m.refresh())), False, False, 0)
            root.pack_start(margins(row, bottom=10), False, False, 0)
        root.pack_start(margins(divider(), top=4, bottom=14), False, False, 0)
        root.pack_start(caption("ABOUT"), False, False, 0)
        about = hbox(12)
        if os.path.isfile(ICON_PATH):
            about.pack_start(Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(ICON_PATH, 40, 40)), False, False, 0)
        names = vbox(1)
        names.set_valign(Gtk.Align.CENTER)
        names.pack_start(label(span("OpenUsage", 13.5, weight="bold")), False, False, 0)
        version = "..." if not u["version"] else f"v{u['version']}" + (f" · {u['commit']}" if u["commit"] else "")
        names.pack_start(label(span(version, 11.5, C["muted"], mono=True)), False, False, 0)
        about.pack_start(names, False, False, 0)
        root.pack_start(about, False, False, 0)

        pill = margins(hbox(9), 8, 10, 8, 10)
        dot = Gtk.DrawingArea()
        dot.set_size_request(8, 8)
        dot.set_valign(Gtk.Align.CENTER)
        color = status[1]

        def draw_dot(_w, cr):
            cr.set_source_rgb(*rgb(color))
            cr.arc(4, 4, 4, 0, 2 * math.pi)
            cr.fill()

        dot.connect("draw", draw_dot)
        pill.pack_start(dot, False, False, 0)
        pill.pack_start(label(span(status[0], 12.5), wrap=True), True, True, 0)
        box = styled(vbox(), "status")
        box.pack_start(pill, True, True, 0)
        root.pack_start(margins(box, top=12), False, False, 0)

        buttons = hbox(8)
        idle = not u["busy"]
        if u["behind"] > 0 and not u["error"]:
            buttons.pack_end(dialog_button("Update now", lambda: m.run_update("apply", self.relaunch), True, idle), False, False, 0)
        buttons.pack_end(dialog_button("Check for updates", lambda: m.run_update("check"), False, idle), False, False, 0)
        root.pack_start(margins(buttons, top=14), False, False, 0)
        if getattr(self, "settings_intro", False):
            self.settings_intro = False
            for i, child in enumerate(root.get_children()):
                fade_in(child, min(i, 16), step=22)
        self.settings_win.set_content(root)

    def relaunch(self):
        """The widget itself is part of the update: start the new code, then quit this copy."""
        try:
            Gio.Subprocess.new(
                ["/bin/sh", "-c", 'sleep 1; exec "$0" "$1"', sys.executable, os.path.abspath(__file__)],
                Gio.SubprocessFlags.NONE,
            )
        except GLib.Error:
            return
        self.quit()

    # ---- window

    def show_window(self):
        # Opening fades the widget in (where the desktop composites windows; elsewhere it just appears).
        self.hiding = False
        appearing = not self.win.get_visible()
        # Reopened mid fade-out: back to full at once.
        self.win.set_opacity(0 if appearing else 1)
        self.win.deiconify()
        self.win.show()
        self.win.present()
        if appearing:
            animate(self.win, 220, lambda k: self.win.set_opacity(ease_out(k)))

    def fade_out(self):
        """Closing: a quick fade, then hidden."""
        if getattr(self, "hiding", False):
            return
        self.hiding = True

        def step(k):
            if not self.hiding:
                return
            self.win.set_opacity(1 - ease_out(k))
            if k >= 1:
                self.hiding = False
                self.win.hide()
                self.win.set_opacity(1)
        animate(self.win, 170, step)

    def hide_window(self):
        # Without a tray icon to bring it back, minimizing keeps it one click away in the taskbar.
        if self.has_tray:
            self.fade_out()
        else:
            self.win.iconify()

    def toggle_window(self):
        if self.win.get_visible() and not getattr(self, "hiding", False):
            self.fade_out()
        else:
            self.show_window()

    def set_topmost(self, on):
        self.topmost = on
        self.win.set_keep_above(on)
        save_setting("topmost", on)

    # ---- menus and tray

    def make_menu(self, tray=False):
        menu = Gtk.Menu()

        def item(text, action):
            mi = Gtk.MenuItem(label=text)
            mi.connect("activate", lambda *_: action())
            menu.append(mi)

        def check(text, active, action):
            mi = Gtk.CheckMenuItem(label=text)
            mi.set_active(active)
            mi.connect("toggled", lambda w: action(w.get_active()))
            menu.append(mi)

        if tray:
            item("Show / hide", self.toggle_window)
        item("Refresh", self.model.refresh)
        item("Settings…", self.show_settings)
        for k in ACCOUNT_KINDS:
            item(f"Add {k['name']} account…", lambda k=k: self.add_account(k))
        menu.append(Gtk.SeparatorMenuItem())
        check("Always on top", self.topmost, self.set_topmost)
        check("Start at login", os.path.isfile(AUTOSTART_FILE), set_start_at_login)
        menu.append(Gtk.SeparatorMenuItem())
        item("Quit", self.quit)
        menu.show_all()
        return menu

    def setup_tray(self):
        if Indicator is not None:
            ind = Indicator.Indicator.new("openusage", ICON_PATH, Indicator.IndicatorCategory.APPLICATION_STATUS)
            ind.set_status(Indicator.IndicatorStatus.ACTIVE)
            ind.set_title(self.model.tray_text())
            # AppIndicator menus are static: rebuild on change so the check items stay true.
            ind.set_menu(self.make_menu(tray=True))
            self.tray = ind
            self.tray_embedded(True)
            return
        icon = Gtk.StatusIcon()
        if os.path.isfile(ICON_PATH):
            icon.set_from_file(ICON_PATH)
        icon.set_tooltip_text(self.model.tray_text())
        icon.set_title("OpenUsage")
        icon.connect("activate", lambda *_: self.toggle_window())
        icon.connect(
            "popup-menu",
            lambda ic, button, t: self.make_menu(tray=True).popup(None, None, Gtk.StatusIcon.position_menu, ic, button, t),
        )
        self.tray = icon
        # Some desktops have no tray at all (stock GNOME): then the window stays in the taskbar instead.
        icon.connect("notify::embedded", lambda ic, _p: self.tray_embedded(ic.is_embedded()))
        GLib.timeout_add(1500, lambda: self.tray_embedded(icon.is_embedded()) and False)

    def tray_embedded(self, on):
        if on == self.has_tray:
            return
        self.has_tray = on
        self.win.set_skip_taskbar_hint(on)
        self.win.set_skip_pager_hint(on)
        if not on and not self.win.get_visible():
            self.show_window()
        self.build()

    def update_tray(self):
        if self.tray is None:
            return
        text = self.model.tray_text()
        if isinstance(self.tray, Gtk.StatusIcon):
            self.tray.set_tooltip_text(text)
        else:
            self.tray.set_title(text)
            self.tray.set_menu(self.make_menu(tray=True))

    def show_add_menu(self):
        menu = Gtk.Menu()
        for k in ACCOUNT_KINDS:
            mi = Gtk.MenuItem(label=f"Add {k['name']} account…")
            mi.connect("activate", lambda _w, k=k: self.add_account(k))
            menu.append(mi)
        menu.show_all()
        menu.attach_to_widget(self.win, None)
        menu.popup_at_pointer(Gtk.get_current_event())

    # ---- accounts

    def add_account(self, k):
        n = 2
        while account_name_problem(k, f"{k['command']}{n}") is not None:
            n += 1
        name = self.ask_account_name(k, f"{k['command']}{n}")
        if name is None:
            return

        # The terminal runs a small script that marks when it is done, since most terminals return at once.
        base = os.path.join(tempfile.gettempdir(), f"openusage-add-{uuid.uuid4()}")
        done, script = base + ".done", base + ".sh"
        node = find_node()
        lines = [
            "#!/bin/bash",
            f"cd {shell_quote(ROOT)}",
            f"{shell_quote(node) if node else 'node'} --experimental-strip-types --no-warnings scripts/add-account.ts "
            f"{k['id']} {shell_quote(name)}",
            "rc=$?",
            f"touch {shell_quote(done)}",
            "echo",
            "read -r -p 'Press Enter to close' _",
            "exit $rc",
        ]
        argv = terminal_argv(script)
        if argv is None:
            self.model.last_error = "no terminal found"
            self.changed()
            return
        try:
            write_text(script, "\n".join(lines) + "\n", 0o755)
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE)
        except (OSError, GLib.Error):
            self.model.last_error = "could not add account"
            self.changed()
            return

        # When the terminal is done, fetch again so the new account shows up.
        waited = [0]

        def poll():
            waited[0] += 3
            if os.path.exists(done):
                for p in (done, script):
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                self.model.refresh()
                return False
            return waited[0] <= 30 * 60

        GLib.timeout_add_seconds(3, poll)

    def ask_key(self, pid):
        """Asks for an API key, checks it with the service, keeps it and fetches again; stays open on a bad key."""
        m, name = self.model, PROVIDER_NAMES[pid]
        url = (m.keys.get(pid) or {}).get("url", "")
        dialog = Gtk.MessageDialog(
            transient_for=self.settings_win or self.win,
            modal=True,
            message_type=Gtk.MessageType.OTHER,
            buttons=Gtk.ButtonsType.NONE,
            text=f"{name} API key",
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        save = dialog.add_button("Save", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.set_keep_above(True)
        area = dialog.get_message_area()
        if url:
            link = Gtk.LinkButton.new_with_label(url, "Create one at " + url.split("://")[-1].rstrip("/"))
            link.set_halign(Gtk.Align.START)
            area.pack_start(link, False, False, 0)
        entry = Gtk.Entry()
        entry.set_visibility(False)
        entry.set_activates_default(True)
        entry.set_width_chars(36)
        area.pack_start(entry, False, False, 0)
        intro = f"{name} has no app sign-in to read, so it needs an API key. It stays on this computer and goes to {name} alone."
        dialog.format_secondary_text(intro)
        save.set_sensitive(False)
        entry.connect("changed", lambda e: save.set_sensitive(bool(e.get_text().strip())))

        def checked(error):
            if error:
                dialog.format_secondary_text(f"{error}\n\n{intro}")
                entry.set_sensitive(True)
                save.set_sensitive(True)
                entry.grab_focus()
            else:
                dialog.destroy()
                m.refresh()

        def respond(_d, response):
            if response != Gtk.ResponseType.OK:
                dialog.destroy()
                return
            entry.set_sensitive(False)
            save.set_sensitive(False)
            dialog.format_secondary_text(f"Checking the key with {name}...")
            if not m.run_keys(["set", pid], entry.get_text().strip(), checked):
                checked("Busy, try again in a moment.")

        dialog.connect("response", respond)
        dialog.show_all()
        entry.grab_focus()

    def ask_account_name(self, k, suggested):
        """Native prompt for the new account's command name; None when cancelled."""
        dialog = Gtk.MessageDialog(
            transient_for=self.win,
            modal=True,
            message_type=Gtk.MessageType.OTHER,
            buttons=Gtk.ButtonsType.NONE,
            text=f"Add {k['name']} account",
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Sign in", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.set_keep_above(True)
        entry = Gtk.Entry()
        entry.set_text(suggested)
        entry.set_activates_default(True)
        entry.set_width_chars(28)
        entry.get_style_context().add_class("monospace")
        dialog.get_message_area().pack_start(entry, False, False, 0)
        intro = "Command that opens this account from any terminal."
        note = intro
        try:
            while True:
                dialog.format_secondary_text(note)
                dialog.show_all()
                entry.grab_focus()
                if dialog.run() != Gtk.ResponseType.OK:
                    return None
                name = entry.get_text().strip()
                problem = account_name_problem(k, name)
                if problem is None:
                    return name
                note = f"{problem}\n\n{intro}"
        finally:
            dialog.destroy()


def install():
    """Adds OpenUsage to the app menu and remembers which node to run."""
    node = shutil.which("node")
    if node:
        write_text(NODE_FILE, node + "\n")
    write_text(LAUNCHER_FILE, desktop_entry())
    if os.path.isfile(AUTOSTART_FILE):
        write_text(AUTOSTART_FILE, desktop_entry(autostart=True))
    print(f"Added {LAUNCHER_FILE}")
    if not node:
        print("warning: node not found on PATH; the widget will try a login shell", file=sys.stderr)


def uninstall():
    for p in (LAUNCHER_FILE, AUTOSTART_FILE, NODE_FILE):
        try:
            os.remove(p)
            print(f"Removed {p}")
        except OSError:
            pass


if __name__ == "__main__":
    if "--install" in sys.argv[1:]:
        install()
    elif "--uninstall" in sys.argv[1:]:
        uninstall()
    else:
        GLib.set_prgname("openusage")
        Gdk.set_program_class("openusage")  # WM_CLASS, matched by StartupWMClass in the launcher
        GLib.set_application_name("OpenUsage")
        sys.exit(App().run([sys.argv[0]]))
