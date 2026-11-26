import os
import socket
import signal
import argparse
import json
import shutil
import subprocess
import threading
import sys
from pathlib import Path
from urllib.parse import urlencode

from omajelly.connection import client_from_saved
from omajelly.ids import valid_item_id



def control_socket():
    return f"/run/user/{os.getuid()}/omajellymusic-player.sock"


def player_command(read_pause=False):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        try:
            client.connect(control_socket())
        except (FileNotFoundError, ConnectionRefusedError):
            raise SystemExit("No active OmaJelly music player.")
        command = ["get_property", "pause"] if read_pause else ["cycle", "pause"]
        client.sendall((json.dumps({"command": command, "request_id": 1}) + "\n").encode())
        with client.makefile("rb") as replies:
            for line in replies:
                reply = json.loads(line)
                if reply.get("request_id") == 1:
                    if reply.get("error") != "success":
                        raise SystemExit(f"mpv: {reply.get('error')}")
                    if read_pause:
                        print(json.dumps(reply["data"]))
                    return 0
        raise SystemExit("mpv closed the connection before replying.")


def player_arguments(socket_path=None, *, persistent=False):
    return [
        sys.executable, str(Path(__file__).resolve().parent / "omajelly/player_process.py"),
        str(os.getpid()), "mpv", "--no-config", "--no-video", "--really-quiet",
        "--audio-client-name=OmaJellyMusic", f"--input-ipc-server={socket_path or control_socket()}",
        *(["--idle=yes", "--pause=yes"] if persistent else ["-"]),
    ]


def play_track(client, item_id):
    with client.open(f"/Audio/{item_id}/stream?static=true") as audio:
        with subprocess.Popen(player_arguments(), stdin=subprocess.PIPE) as player:
            try:
                try:
                    shutil.copyfileobj(audio, player.stdin, length=65536)
                    player.stdin.close()
                except BrokenPipeError:
                    pass
                return player.wait()
            except BaseException:
                # Kill before closing buffered stdin: a paused player may never drain it.
                player.kill()
                player.wait()
                try:
                    player.stdin.close()
                except BrokenPipeError:
                    pass
                raise


def prepare_playback_session(*, graceful=False):
    if os.getpgrp() != os.getpid():
        os.setpgid(0, 0)

    def stop_session(signum, frame):
        if graceful:
            # Unwind the persistent session so its private socket and proxy are closed.
            # The launcher still guarantees cleanup if the owner is killed outright.
            raise SystemExit(0)
        signal.signal(signum, signal.SIG_DFL)
        os.killpg(os.getpid(), signum)

    signal.signal(signal.SIGTERM, stop_session)


def album_cover(client, album_id):
    from pathlib import Path
    from tempfile import NamedTemporaryFile
    from urllib.error import HTTPError
    from omajelly.common import JellyfinError

    directory = Path(os.environ["XDG_RUNTIME_DIR"]) / "omajellymusic-art"
    directory.mkdir(mode=0o700, exist_ok=True)
    target = directory / (album_id + ".jpg")
    try:
        with client.open(
            f"/Items/{album_id}/Images/Primary?maxWidth=160&maxHeight=160&format=jpg",
            timeout=4,
        ) as response:
            data = response.read(512 * 1024 + 1)
        if not data.startswith(bytes.fromhex("ff d8")) or len(data) > 512 * 1024:
            return ""
        with NamedTemporaryFile(dir=directory, delete=False) as temp:
            temp.write(data)
        os.replace(temp.name, target)
        return target.as_uri() + "?album=" + album_id
    except (HTTPError, JellyfinError, OSError):
        return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["playlists", "playlist-tracks", "artists", "albums", "tracks", "play", "play-pause", "paused", "play-album", "play-queue"])
    parser.add_argument("item_id", nargs="?")
    parser.add_argument("--cover-id")
    args = parser.parse_args()
    if args.action in ("play", "play-album", "play-queue"):
        prepare_playback_session(graceful=args.action == "play-queue")
    if args.action in ("play-pause", "paused"):
        return player_command(read_pause=args.action == "paused")
    if args.action not in ("artists", "playlists", "play-queue") and not args.item_id:
        parser.error(f"{args.action} requires an item ID")
    item_id = valid_item_id(args.item_id) if args.item_id else None

    client, config = client_from_saved()
    user_id = config["userId"]

    if args.action == "play-queue":
        from omajelly.music_queue import run_queue
        from omajelly.common import JellyfinError
        output_lock = threading.Lock()

        def emit(value):
            with output_lock:
                print(json.dumps(value), flush=True)

        try:
            rows = json.loads(sys.stdin.readline(2 * 1024 * 1024))
            return run_queue(client, rows, sys.stdin, lambda path: player_arguments(path, persistent=True),
                             control_socket(), emit, lambda key: album_cover(client, key))
        except (OSError, EOFError, ValueError, RuntimeError, KeyError, TypeError, JellyfinError):
            return 1

    if args.action == "play":
        if args.cover_id:
            cover_id = valid_item_id(args.cover_id)
            def send_cover():
                url = album_cover(client, cover_id)
                print(json.dumps({"track": item_id, "cover": url}), flush=True)
            threading.Thread(target=send_cover, daemon=True).start()
        return play_track(client, item_id)

    path = f"/Users/{user_id}/Items"
    query = {"SortBy": "SortName", "SortOrder": "Ascending"}
    if args.action == "artists":
        path = "/Artists/AlbumArtists"
        query["UserId"] = user_id
    elif args.action == "playlists":
        query.update(IncludeItemTypes="Playlist", Recursive="true")
    elif args.action == "playlist-tracks":
        path = f"/Playlists/{item_id}/Items"
        query = {"UserId": user_id}
    elif args.action == "albums":
        query.update(AlbumArtistIds=item_id, IncludeItemTypes="MusicAlbum",
                     Recursive="true")
    else:
        query.update(ParentId=item_id, IncludeItemTypes="Audio", Recursive="true",
                     SortBy="ParentIndexNumber,IndexNumber,SortName")

    rows = []
    offset = 0
    while True:
        query.update(StartIndex=offset, Limit=100)
        page = client.request_json(f"{path}?{urlencode(query)}")
        items = page["Items"]
        offset += len(items)
        for item in items:
            if args.action == "playlist-tracks" and item.get("Type") != "Audio":
                continue
            if args.action == "playlists" and item.get("MediaType") in ("Video", "Photo", "Book"):
                continue
            row = {"id": item["Id"], "name": item["Name"]}
            if args.action in ("tracks", "playlist-tracks"):
                row.update(artists=item.get("Artists") or [],
                           lengthUs=(item.get("RunTimeTicks") or 0) // 10)
            if args.action == "playlist-tracks":
                row.update(album=item.get("Album") or "", coverId=item.get("AlbumId") or item["Id"])
            rows.append(row)
        if not items or offset >= page.get("TotalRecordCount", float("inf")):
            break
    if args.action == "play-album":
        if not rows:
            raise SystemExit("This album has no playable tracks.")
        for row in rows:
            status = play_track(client, valid_item_id(row["id"]))
            if status != 0:
                return status
        return 0
    if args.action == "tracks" and rows:
        rows[0]["cover"] = album_cover(client, item_id)
    print(json.dumps(rows, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
