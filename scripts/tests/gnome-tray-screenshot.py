#!/usr/bin/env python3
"""Validates native AppIndicator screenshots in an isolated headless GNOME session."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops


def main():
    if sys.argv[1] == "--compare":
        compare(Path(sys.argv[2]), expected=6)
        return

    client = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gnome-tray-") as session:
        try:
            capture(client, output, Path(session))
        finally:
            # The document portal outlives the shell until dbus-run-session exits.
            portal_mount = Path(session) / "runtime/doc"
            if os.path.ismount(portal_mount):
                subprocess.run(["fusermount3", "-u", str(portal_mount)], check=True)


def capture(client, output, session):
    from gi.repository import Gio, GLib

    environment = {
        "XDG_RUNTIME_DIR": str(session / "runtime"),
        "XDG_CONFIG_HOME": str(session / "config"),
        "XDG_DATA_HOME": str(session / "data"),
        "XDG_CACHE_HOME": str(session / "cache"),
        "XDG_CURRENT_DESKTOP": "GNOME",
        "XDG_SESSION_TYPE": "wayland",
        "GNOME_SHELL_SESSION_MODE": "user",
        "WAYLAND_DISPLAY": "wayland-0",
        "GDK_BACKEND": "wayland",
        "LIBGL_ALWAYS_SOFTWARE": "1",
        "GALLIUM_DRIVER": "llvmpipe",
        "LP_NUM_THREADS": "1",
        "GTK_THEME": "Yaru",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "FIREZONE_NO_TELEMETRY": "true",
    }
    for name in ["runtime", "config", "data", "cache"]:
        (session / name).mkdir(mode=0o700)
    os.environ.update(environment)
    os.environ.pop("DISPLAY", None)
    subprocess.run(["dbus-update-activation-environment", *environment], check=True)

    for schema, key, value in [
        ("org.gnome.desktop.interface", "enable-animations", "false"),
        ("org.gnome.desktop.interface", "color-scheme", "prefer-light"),
        ("org.gnome.desktop.interface", "font-name", "Cantarell 11"),
        ("org.gnome.desktop.interface", "text-scaling-factor", "1.0"),
        ("org.gnome.desktop.interface", "scaling-factor", "1"),
        ("org.gnome.desktop.session", "idle-delay", "0"),
        ("org.gnome.desktop.screensaver", "lock-enabled", "false"),
        ("org.gnome.desktop.background", "picture-uri", "''"),
        ("org.gnome.desktop.background", "picture-uri-dark", "''"),
        ("org.gnome.desktop.background", "primary-color", "#ffffff"),
        ("org.gnome.desktop.background", "color-shading-type", "solid"),
        ("org.gnome.shell", "welcome-dialog-last-shown-version", "999"),
        ("org.gnome.shell", "disable-user-extensions", "false"),
        ("org.gnome.shell", "enabled-extensions", "['ubuntu-appindicators@ubuntu.com']"),
    ]:
        subprocess.run(["gsettings", "set", schema, key, value], check=True)

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def call(destination, path, interface, method, signature, args):
        return bus.call_sync(
            destination, path, interface, method, GLib.Variant(signature, args),
            None, Gio.DBusCallFlags.NONE, 10000, None,
        ).unpack()

    def evaluate(code):
        ok, value = call("org.gnome.Shell", "/org/gnome/Shell", "org.gnome.Shell",
                         "Eval", "(s)", (code,))
        if not ok:
            raise RuntimeError(f"GNOME Eval failed: {value}")
        return json.loads(value) if value else None

    def screenshot(bounds, path):
        ok, filename = call("org.gnome.Shell.Screenshot", "/org/gnome/Shell/Screenshot",
                            "org.gnome.Shell.Screenshot", "ScreenshotArea", "(iiiibs)",
                            (*bounds, False, str(path)))
        if not ok or not path.is_file():
            raise RuntimeError(f"ScreenshotArea failed: {filename}")

    with (output / "gnome-shell.log").open("w") as shell_log, (output / "client.log").open("w") as client_log:
        shell = subprocess.Popen([
            "gnome-shell", "--wayland", "--headless", "--virtual-monitor", "1920x1080",
            "--unsafe-mode",
        ], stdout=shell_log, stderr=subprocess.STDOUT)
        gui = None
        try:
            wait_for("GNOME Shell", lambda: evaluate("!Main.layoutManager._startingUp"), shell)
            wait_for("StatusNotifierWatcher", lambda: call(
                "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                "NameHasOwner", "(s)", ("org.kde.StatusNotifierWatcher",),
            )[0], shell)

            resource = Path("/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource")
            entries = subprocess.check_output(["gresource", "list", str(resource)], text=True).splitlines()
            css_entry = next(entry for entry in entries if entry.endswith("/gnome-shell.css"))
            css = session / "yaru.css"
            css.write_bytes(subprocess.check_output(["gresource", "extract", str(resource), css_entry]))
            print("Yaru resource:", resource, "stylesheet:", css_entry, flush=True)
            evaluate(f"""(() => {{
                global.firezoneScreenshotTheme = Gio.Resource.load({json.dumps(str(resource))});
                global.firezoneScreenshotTheme._register();
                Main.setThemeStylesheet({json.dumps(str(css))});
                Main.loadTheme();
                Main.overview.hide();
                Main.welcomeDialog?.close();
                return true;
            }})()""")
            subprocess.run(["gnome-keyring-daemon", "--unlock", "--components=secrets"],
                           input="", text=True, check=True, timeout=10)
            wait_for("Wayland display", lambda: (session / "runtime/wayland-0").exists(), shell)
            gui = subprocess.Popen([
                str(client), "--mock-tunnel", "--skip-portal-auth", "--no-error-dialog",
                "--no-deep-links", "--no-elevation-check",
            ], stdout=client_log, stderr=subprocess.STDOUT)

            wait_for("Engineering wiki in the native menu", lambda: evaluate("""(() => {
                const describe = menu => menu?._getMenuItems().map(item => ({
                    label: item.label?.text, visible: item.visible,
                    children: item.menu ? describe(item.menu) : undefined,
                }));
                global.firezoneScreenshotState = Object.entries(Main.panel.statusArea)
                    .filter(([name]) => name.startsWith('appindicator-'))
                    .map(([name, item]) => ({name, id: item._indicator?.id,
                        ready: item._menuClient?.isReady,
                        pendingLayout: item._menuClient?._client._flagLayoutUpdateRequired,
                        menu: describe(item.menu)}));
                const indicator = Object.values(Main.panel.statusArea).find(
                    item => item._indicator?.id === 'dev.firezone.client');
                if (!indicator) return false;
                global.get_window_actors().forEach(actor => actor.meta_window.minimize());
                // An empty PopupMenu cannot open to activate deferred DBusMenu updates.
                if (indicator._menuClient)
                    indicator._menuClient._client.active = true;
                indicator.menu.open(false);
                const wiki = indicator.menu._getMenuItems().find(
                    item => item.label?.text === 'Engineering wiki');
                if (!wiki?.menu) return false;
                wiki.menu.open(false);
                global.firezoneScreenshotMenu = indicator.menu;
                global.firezoneScreenshotSubmenu = wiki.menu;
                return wiki.menu._getMenuItems().some(item => item.label?.text);
            })()"""), shell, gui)
            print("Native menu:", evaluate("global.firezoneScreenshotState"), flush=True)

            geometry = """(() => {
                const menus = [global.firezoneScreenshotMenu, global.firezoneScreenshotSubmenu];
                if (menus.some(menu => !menu.isOpen || !menu.actor.mapped)) return null;
                const rects = menus.map(menu => {
                    const [x, y] = menu.actor.get_transformed_position();
                    const [width, height] = menu.actor.get_transformed_size();
                    return [x, y, x + width, y + height];
                });
                const x = Math.floor(Math.min(...rects.map(rect => rect[0])));
                const y = Math.floor(Math.min(...rects.map(rect => rect[1])));
                const right = Math.ceil(Math.max(...rects.map(rect => rect[2])));
                const bottom = Math.ceil(Math.max(...rects.map(rect => rect[3])));
                return [x, y, right - x, bottom - y];
            })()"""
            wait_for("visible menu geometry", lambda: evaluate(geometry), shell, gui)
            time.sleep(2)
            bounds = evaluate(geometry)
            if not bounds or bounds[2] <= 0 or bounds[3] <= 0:
                raise RuntimeError(f"Invalid menu bounds: {bounds}")
            print("Menu bounds:", bounds, flush=True)
            (output / "geometry.json").write_text(json.dumps(bounds) + "\n")
            for attempt in [1, 2]:
                if evaluate(geometry) != bounds:
                    raise RuntimeError("Menu geometry changed between captures")
                screenshot(bounds, output / f"gnome-tray-menu-light-{attempt}.png")
                time.sleep(2)
            screenshot((0, 0, 1920, 1080), output / "desktop.png")
            compare(output, expected=2)
        except Exception:
            try:
                print("Shell state:", evaluate("""({
                    panel: global.firezoneScreenshotState,
                    extensions: Main.extensionManager.getUuids().map(uuid => {
                        const extension = Main.extensionManager.lookup(uuid);
                        return {uuid, state: extension.state, errors: extension.errors};
                    })
                })"""), flush=True)
                screenshot((0, 0, 1920, 1080), output / "failure-desktop.png")
            except Exception as error:
                print("Failed to collect shell diagnostics:", error, flush=True)
            raise
        finally:
            for process in [gui, shell]:
                if process is None:
                    continue
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            print((output / "gnome-shell.log").read_text(), flush=True)
            print((output / "client.log").read_text(), flush=True)


def wait_for(description, predicate, *processes):
    deadline = time.monotonic() + 90
    last_error = None
    while time.monotonic() < deadline:
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(f"Process exited with {process.returncode} waiting for {description}")
        try:
            if predicate():
                print("Ready:", description, flush=True)
                return
        except Exception as error:
            last_error = error
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for {description}: {last_error}")


def compare(directory, expected):
    paths = sorted(directory.rglob("gnome-tray-menu-light-*.png"))
    if len(paths) != expected:
        raise RuntimeError(f"Expected {expected} screenshots, found {len(paths)}")
    baseline = Image.open(paths[0]).convert("RGB")
    for path in paths:
        pixels = Image.open(path).convert("RGB")
        digest = hashlib.sha256(pixels.tobytes()).hexdigest()
        print(path, pixels.size, digest, flush=True)
        if pixels.size != baseline.size or ImageChops.difference(baseline, pixels).getbbox():
            raise RuntimeError(f"Screenshot pixels differ: {paths[0]} and {path}")
    print(f"All {expected} captures are pixel-identical", flush=True)


if __name__ == "__main__":
    main()
