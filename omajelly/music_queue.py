"""Own one mpv process and its authenticated stream URLs for a music queue."""
import contextlib
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import subprocess
import tempfile
import threading
import time

from omajelly.ids import valid_item_id
from omajelly.music_stream import ThreadedServer, proxy_handler


def validate_queue(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 10000:
        raise ValueError("Invalid music queue")
    return [{"id": valid_item_id(row["id"]),
             "coverId": valid_item_id(row.get("coverId"), required=False)} for row in value]


def read_message(reader):
    line = reader.readline(4 * 1024 * 1024)
    if not line:
        raise EOFError("Player disconnected")
    return json.loads(line)


def send_command(connection, command, request_id=None):
    message = {"command": command}
    if request_id is not None:
        message["request_id"] = request_id
    connection.sendall((json.dumps(message) + "\n").encode())


def request(connection, reader, command, request_id, events):
    send_command(connection, command, request_id)
    while True:
        reply = read_message(reader)
        if reply.get("request_id") == request_id:
            if reply.get("error") != "success":
                raise RuntimeError("mpv rejected a playlist command")
            return reply.get("data")
        if "event" in reply:
            events.append(reply)


def connect_player(player, path):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if player.poll() is not None:
            break
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.connect(path)
            return connection
        except OSError:
            pass
        connection.close()
        time.sleep(0.03)
    raise RuntimeError("Music player did not start")


def run_queue(client, rows, commands, arguments_for_socket, socket_path, emit, cover):
    rows = validate_queue(rows)
    secret = secrets.token_urlsafe(24)
    paths = [f"/{secret}/{index}" for index in range(len(rows))]
    routes = {path: f'/Audio/{row["id"]}/stream?static=true' for path, row in zip(paths, rows)}
    with ThreadedServer(("127.0.0.1", 0), proxy_handler(client, routes)) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix="omajellymusic-queue-") as directory:
                playlist = Path(directory) / "queue.m3u"
                playlist.write_text("#EXTM3U\n" + "\n".join(f"http://127.0.0.1:{server.server_port}{path}" for path in paths) + "\n")
                private_socket = str(Path(directory) / "mpv.sock")
                return play_playlist(rows, commands, arguments_for_socket(private_socket), private_socket,
                                     socket_path, playlist, emit, cover)
        finally:
            server.shutdown()


def publish_socket(private_socket, public_socket):
    # The old process can never unlink the new process's private socket.
    temporary = public_socket + "." + secrets.token_hex(8)
    try:
        os.symlink(private_socket, temporary)
        os.replace(temporary, public_socket)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def play_playlist(rows, commands, arguments, private_socket, public_socket, playlist, emit, cover):
    pending_covers = queue.Queue(maxsize=1)
    stopped = threading.Event()
    player = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    try:
        with connect_player(player, private_socket) as connection, connection.makefile("rb") as reader:
            # Start paused so even a very short first song cannot finish before its ID is known.
            connection.settimeout(10)
            events = []
            request(connection, reader, ["observe_property", 1, "pause"], 1, events)
            request(connection, reader, ["loadlist", str(playlist), "replace"], 2, events)
            entries = request(connection, reader, ["get_property", "playlist"], 3, events)
            if len(entries) != len(rows):
                raise RuntimeError("mpv did not load the complete queue")
            positions = {entry["id"]: index for index, entry in enumerate(entries)}
            request(connection, reader, ["set_property", "pause", False], 4, events)
            connection.settimeout(None)
            publish_socket(private_socket, public_socket)
            emit({"type": "ready"})

            def cover_worker():
                while True:
                    job = pending_covers.get()
                    if job is None or stopped.is_set():
                        return
                    index, cover_id = job
                    try:
                        url = cover(cover_id)
                    except Exception:
                        url = ""
                    if not stopped.is_set():
                        emit({"type": "cover", "index": index, "cover": url})

            def control_worker():
                try:
                    for line in commands:
                        if stopped.is_set():
                            return
                        message = json.loads(line)
                        if message.get("action") == "jump":
                            index = message.get("index")
                            if type(index) is int and 0 <= index < len(rows):
                                send_command(connection, ["playlist-play-index", index])
                                send_command(connection, ["set_property", "pause", False])
                        elif message.get("action") == "toggle":
                            send_command(connection, ["cycle", "pause"])
                    send_command(connection, ["quit"])
                except (OSError, ValueError):
                    pass

            threading.Thread(target=control_worker, daemon=True).start()
            threading.Thread(target=cover_worker, daemon=True).start()
            current = None
            while True:
                event = events.pop(0) if events else read_message(reader)
                kind = event.get("event")
                if kind == "start-file":
                    current = positions.get(event.get("playlist_entry_id"))
                    if current is not None:
                        emit({"type": "loading", "index": current})
                elif kind == "file-loaded" and current is not None:
                    emit({"type": "track", "index": current})
                    cover_id = rows[current]["coverId"]
                    if cover_id:
                        with contextlib.suppress(queue.Empty):
                            pending_covers.get_nowait()
                        pending_covers.put_nowait((current, cover_id))
                elif kind == "property-change" and event.get("name") == "pause":
                    emit({"type": "paused", "value": event.get("data") is True})
                elif kind == "end-file":
                    reason = event.get("reason")
                    if reason == "error":
                        return 1
                    if reason == "eof" and positions.get(event.get("playlist_entry_id")) == len(rows) - 1:
                        return 0
                    if reason == "quit":
                        return 0
                elif kind == "shutdown":
                    return player.wait(timeout=2)
    finally:
        stopped.set()
        with contextlib.suppress(queue.Empty):
            pending_covers.get_nowait()
        pending_covers.put_nowait(None)
        # Never remove a newer session's IPC alias.
        with contextlib.suppress(OSError):
            if os.readlink(public_socket) == private_socket:
                os.unlink(public_socket)
        if player.poll() is None:
            player.terminate()
            try:
                player.wait(timeout=2)
            except subprocess.TimeoutExpired:
                player.kill()
                player.wait()
