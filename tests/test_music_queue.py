import io
import os
from pathlib import Path
import queue
import json
import select
import socket
import subprocess
import sys
import shutil
import tempfile
import threading
import unittest
import wave
from urllib.error import HTTPError

import music_helper
from omajelly.music_queue import run_queue, validate_queue


class AudioResponse(io.BytesIO):
    def __init__(self, data, range_header):
        self.status = 200
        self.headers = {"Content-Type": "audio/wav", "Accept-Ranges": "bytes"}
        if range_header:
            start = int(range_header.removeprefix("bytes=").split("-")[0] or 0)
            self.headers["Content-Range"] = f"bytes {start}-{len(data)-1}/{len(data)}"
            self.status = 206
            data = data[start:]
        self.headers["Content-Length"] = str(len(data))
        super().__init__(data)

    def getcode(self):
        return self.status


class Client:
    def __init__(self, duration, fail=False):
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as wav:
            wav.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0\0" * int(8000 * duration))
        self.audio = buffer.getvalue()
        self.paths = []
        self.fail = fail

    def open(self, path, *, method, range_header):
        self.paths.append(path)
        if self.fail and path.startswith("/Audio/" + "b" * 32):
            raise HTTPError("http://example.invalid", 404, "Not found", {}, None)
        return AudioResponse(self.audio, range_header)


ROWS = [{"id": "a" * 32}, {"id": "b" * 32}, {"id": "a" * 32}]


class QueueTests(unittest.TestCase):
    def test_duplicate_tracks_remain_distinct(self):
        self.assertEqual([row["id"] for row in validate_queue(ROWS)], [row["id"] for row in ROWS])

    @unittest.skipUnless(shutil.which("mpv"), "mpv not installed")
    def test_natural_advancement_uses_one_process(self):
        self.run_real_queue(0.18, [0, 1, 2])

    @unittest.skipUnless(shutil.which("mpv"), "mpv not installed")
    def test_manual_jump_while_paused(self):
        self.run_real_queue(0.8, [0, 2], mode="jump")

    @unittest.skipUnless(shutil.which("mpv"), "mpv not installed")
    def test_pause_resume_and_previous(self):
        self.run_real_queue(0.45, [0, 1, 0, 2], mode="previous")

    @unittest.skipUnless(shutil.which("mpv"), "mpv not installed")
    def test_failed_track_stops_queue(self):
        self.run_real_queue(0.18, [0], fail=True)

    @unittest.skipUnless(shutil.which("mpv"), "mpv not installed")
    def test_terminate_cleans_up_queue_socket_and_player(self):
        code = """import json, sys
import music_helper
from omajelly.music_queue import run_queue
from tests.test_music_queue import Client, ROWS
music_helper.prepare_playback_session(graceful=True)
run_queue(Client(20), ROWS, sys.stdin,
          lambda path: music_helper.player_arguments(path, persistent=True) + ['--ao=null'],
          sys.argv[1], lambda event: print(json.dumps(event), flush=True), lambda _: '')
"""
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "mpv.sock")
            with subprocess.Popen([sys.executable, "-c", code, path], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True) as owner:
                try:
                    self.assertTrue(select.select([owner.stdout], [], [], 8)[0], "player did not start")
                    self.assertEqual(json.loads(owner.stdout.readline()), {"type": "ready"})
                    with socket.socket(socket.AF_UNIX) as sock:
                        sock.settimeout(2)
                        sock.connect(path)
                        sock.sendall(b'{"command":["get_property","pid"],"request_id":1}\n')
                        with sock.makefile("rb") as reply:
                            pid = next(data["data"] for line in reply if (data := json.loads(line)).get("request_id") == 1)
                    owner.terminate()
                    self.assertEqual(owner.wait(timeout=5), 0)
                    self.assertFalse(os.path.lexists(path))
                    self.assertFalse(Path(f"/proc/{pid}").exists())
                finally:
                    if owner.poll() is None:
                        owner.kill()
                        owner.wait(timeout=5)

    def run_real_queue(self, duration, expected, mode=None, fail=False):
        client = Client(duration, fail=fail)
        events = []
        commands = queue.Queue()
        pids = set()
        failure = []
        result = []
        timed_out = threading.Event()
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "mpv.sock")
            arguments = lambda private: music_helper.player_arguments(private, persistent=True) + ["--ao=null"]
            def emit(event):
                events.append(event)
                if event["type"] == "track":
                    # Find the socket-owning mpv PID through its IPC command.
                    with socket.socket(socket.AF_UNIX) as sock:
                        sock.connect(path)
                        sock.sendall(b'{"command":["get_property","pid"],"request_id":1}\n')
                        with sock.makefile("rb") as reply:
                            for line in reply:
                                data = json.loads(line)
                                if data.get("request_id") == 1:
                                    pids.add(data["data"])
                                    break
                    played = [e["index"] for e in events if e["type"] == "track"]
                    if mode and played == [0]:
                        commands.put('{"action":"toggle"}')
                    elif mode == "previous" and played == [0, 1]:
                        commands.put('{"action":"jump","index":0}')
                    elif mode == "previous" and played == [0, 1, 0]:
                        commands.put('{"action":"jump","index":2}')
                elif mode and event == {"type": "paused", "value": True} and any(e.get("type") == "track" for e in events):
                    commands.put('{"action":"jump","index":2}' if mode == "jump" else '{"action":"toggle"}')
            def run():
                try:
                    result.append(run_queue(client, ROWS, iter(commands.get, None), arguments, path, emit, lambda _: ""))
                except Exception as exc:
                    failure.append(exc)
            # Run on the owning main thread. A watchdog sends quit if playback hangs.
            def watchdog():
                timed_out.set()
                commands.put(None)
            timer = threading.Timer(10, watchdog)
            timer.start()
            try:
                run()
            finally:
                timer.cancel()
                commands.put(None)
            self.assertFalse(os.path.lexists(path))
        if failure:
            raise failure[0]
        self.assertFalse(timed_out.is_set(), events)
        self.assertEqual(result, [1 if fail else 0], events)
        self.assertEqual([event["index"] for event in events if event["type"] == "track"], expected, events)
        self.assertEqual(len(pids), 1, events)
        self.assertTrue(all(type(pid) is int and pid > 0 for pid in pids), events)
        self.assertTrue(client.paths)
        if mode:
            self.assertIn({"type": "paused", "value": True}, events)
            self.assertIn({"type": "paused", "value": False}, events)


if __name__ == "__main__":
    unittest.main()
