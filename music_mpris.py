"""Publish the active Omarchy music queue on the user's session bus."""
import json
import os
import socket
import sys
import threading
from pathlib import Path
from urllib.parse import urlsplit, unquote

from gi.repository import Gio, GLib

ROOT = "org.mpris.MediaPlayer2"
PLAYER = ROOT + ".Player"
PATH = "/org/mpris/MediaPlayer2"
V = GLib.Variant
loop = GLib.MainLoop()
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
base = {
    "Identity": V("s", "OmaJelly Music"), "CanQuit": V("b", False),
    "CanRaise": V("b", False), "HasTrackList": V("b", False),
    "SupportedUriSchemes": V("as", []), "SupportedMimeTypes": V("as", []),
}
props = {
    "PlaybackStatus": V("s", "Stopped"), "Metadata": V("a{sv}", {}),
    "Position": V("x", 0), "Rate": V("d", 1), "MinimumRate": V("d", 1),
    "MaximumRate": V("d", 1), "CanControl": V("b", True),
    "CanPlay": V("b", True), "CanPause": V("b", True), "CanSeek": V("b", False),
    "CanGoNext": V("b", False), "CanGoPrevious": V("b", False),
}


def update(values):
    changes = {k: v for k, v in values.items() if not props[k].equal(v)}
    props.update(changes)
    changes.pop("Position", None)
    if changes:
        bus.emit_signal(None, PATH, "org.freedesktop.DBus.Properties",
                        "PropertiesChanged", V("(sa{sv}as)", (PLAYER, changes, [])))


def publish(row):
    track = row["id"].replace("-", "_")
    metadata = {"mpris:trackid": V("o", PATH + "/track/t" + track),
                "xesam:title": V("s", row["title"]), "xesam:album": V("s", row["album"]),
                "xesam:artist": V("as", row["artists"])}
    if row.get("cover"):
        path = urlsplit(row["cover"])
        if path.scheme == "file":
            metadata["mpris:artUrl"] = V("s", Path(unquote(path.path)).as_uri())
    if row.get("length"):
        metadata["mpris:length"] = V("x", int(row["length"]))
    update({"Metadata": V("a{sv}", metadata), "Position": V("x", 0),
            "CanGoNext": V("b", row["next"]), "CanGoPrevious": V("b", row["previous"])})


def read_queue():
    try:
        for line in sys.stdin:
            GLib.idle_add(publish, json.loads(line))
    finally:
        GLib.idle_add(loop.quit)


def mpv(commands):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.35)
        sock.connect(f"/run/user/{os.getuid()}/omajellymusic-player.sock")
        with sock.makefile("rb") as reader:
            for index, command in enumerate(commands, 1):
                sock.sendall((json.dumps({"command": command, "request_id": index}) + "\n").encode())
                for line in reader:
                    reply = json.loads(line)
                    if reply.get("request_id") == index:
                        yield reply.get("data")
                        break


def poll():
    try:
        paused, position = mpv([["get_property", "pause"], ["get_property", "time-pos"]])
        update({"PlaybackStatus": V("s", "Paused" if paused else "Playing"),
                "Position": V("x", int((position or 0) * 1_000_000))})
    except (OSError, ValueError):
        pass
    return True


def method(conn, sender, path, iface, name, args, call):
    cmds = {"PlayPause": ["cycle", "pause"], "Pause": ["set_property", "pause", True],
            "Play": ["set_property", "pause", False]}
    if name in cmds:
        try:
            list(mpv([cmds[name]]))
            poll()
        except OSError as exc:
            call.return_dbus_error("org.freedesktop.DBus.Error.Failed", str(exc))
            return
    elif name in ("Next", "Previous", "Stop"):
        print(name, flush=True)
    else:
        call.return_dbus_error("org.freedesktop.DBus.Error.NotSupported", name)
        return
    call.return_value(None)


def register(interface, properties, methods):
    members = "".join(f'<property name="{k}" type="{v.get_type_string()}" access="read"/>'
                      for k, v in properties.items())
    members += "".join(f'<method name="{name}"/>' for name in methods)
    info = Gio.DBusNodeInfo.new_for_xml(f'<node><interface name="{interface}">{members}</interface></node>')
    bus.register_object(PATH, info.interfaces[0], method,
                        lambda conn, sender, path, iface, name: properties[name], None)


register(ROOT, base, ["Raise", "Quit"])
register(PLAYER, props, ["Next", "Previous", "Pause", "Play", "PlayPause", "Stop"])
Gio.bus_own_name_on_connection(bus, ROOT + ".omajellymusic", Gio.BusNameOwnerFlags.NONE,
                               None, lambda *args: loop.quit())
threading.Thread(target=read_queue, daemon=True).start()
GLib.timeout_add(750, poll)
loop.run()
