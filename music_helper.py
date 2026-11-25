import os
import socket
import signal
import argparse
import json
import shutil
import subprocess
from urllib.parse import urlencode

from omajelly.connection import client_from_saved
from omajelly.ids import valid_item_id



def control_socket():
    return f"/run/user/{os.getuid()}/omajelly-music.sock"


def toggle_pause():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        try:
            client.connect(control_socket())
        except (FileNotFoundError, ConnectionRefusedError):
            raise SystemExit("No active OmaJelly music player.")
        client.sendall(b'{"command":["cycle","pause"],"request_id":1}\n')
        with client.makefile("rb") as replies:
            for line in replies:
                reply = json.loads(line)
                if reply.get("request_id") == 1:
                    if reply.get("error") != "success":
                        raise SystemExit(f"mpv: {reply.get('error')}")
                    return 0
        raise SystemExit("mpv closed the connection before replying.")


def play_track(client, item_id):
    with client.open(f"/Audio/{item_id}/stream?static=true") as audio:
        with subprocess.Popen(
            ["mpv", "--no-config", "--no-video", "--really-quiet", f"--input-ipc-server={control_socket()}", "-"],
            stdin=subprocess.PIPE,
        ) as player:
            try:
                with player.stdin:
                    shutil.copyfileobj(audio, player.stdin, length=65536)
            except BrokenPipeError:
                pass
            return player.wait()


def prepare_playback_session():
    if os.getpgrp() != os.getpid():
        os.setpgid(0, 0)

    def stop_session(signum, frame):
        signal.signal(signum, signal.SIG_DFL)
        os.killpg(os.getpid(), signum)

    signal.signal(signal.SIGTERM, stop_session)


def album_cover(client, album_id):
    from pathlib import Path
    from tempfile import NamedTemporaryFile
    from urllib.error import HTTPError
    from omajelly.common import JellyfinError

    directory = Path(os.environ["XDG_RUNTIME_DIR"]) / "omajelly-art"
    directory.mkdir(mode=0o700, exist_ok=True)
    target = directory / "cover.jpg"
    try:
        with client.open(
            f"/Items/{album_id}/Images/Primary?maxWidth=160&maxHeight=160&format=jpg",
            timeout=4,
        ) as response:
            data = response.read(512 * 1024 + 1)
        if not data.startswith(b"\\xff\\xd8") or len(data) > 512 * 1024:
            return ""
        with NamedTemporaryFile(dir=directory, delete=False) as temp:
            temp.write(data)
        os.replace(temp.name, target)
        return target.as_uri() + "?album=" + album_id
    except (HTTPError, JellyfinError, OSError):
        return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["artists", "albums", "tracks", "play", "play-pause", "play-album"])
    parser.add_argument("item_id", nargs="?")
    args = parser.parse_args()
    if args.action in ("play", "play-album"):
        prepare_playback_session()
    if args.action == "play-pause":
        return toggle_pause()
    if args.action != "artists" and not args.item_id:
        parser.error(f"{args.action} requires an item ID")
    item_id = valid_item_id(args.item_id) if args.item_id else None

    client, config = client_from_saved()
    user_id = config["userId"]

    if args.action == "play":
        return play_track(client, item_id)

    path = f"/Users/{user_id}/Items"
    query = {"SortBy": "SortName", "SortOrder": "Ascending"}
    if args.action == "artists":
        path = "/Artists/AlbumArtists"
        query["UserId"] = user_id
    elif args.action == "albums":
        query.update(AlbumArtistIds=item_id, IncludeItemTypes="MusicAlbum",
                     Recursive="true")
    else:
        query.update(ParentId=item_id, IncludeItemTypes="Audio", Recursive="true",
                     SortBy="ParentIndexNumber,IndexNumber,SortName")

    rows = []
    while True:
        query.update(StartIndex=len(rows), Limit=100)
        page = client.request_json(f"{path}?{urlencode(query)}")
        items = page["Items"]
        rows.extend({"id": item["Id"], "name": item["Name"]} for item in items)
        if not items or len(rows) >= page.get("TotalRecordCount", float("inf")):
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
