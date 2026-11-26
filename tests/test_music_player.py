import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest

import music_helper


LAUNCHER = Path(music_helper.__file__).parent / "omajelly/player_process.py"


class PlayerProcessTests(unittest.TestCase):
    def test_dedicated_audio_identity(self):
        self.assertIn("--audio-client-name=OmaJellyMusic", music_helper.player_arguments())

    def test_launcher_executes_command(self):
        result = subprocess.run([sys.executable, str(LAUNCHER), str(os.getpid()),
                                 sys.executable, "-c", "raise SystemExit(23)"])
        self.assertEqual(result.returncode, 23)

    def test_launcher_rejects_missing_parent(self):
        result = subprocess.run([sys.executable, str(LAUNCHER), "0",
                                 sys.executable, "-c", "raise SystemExit(23)"])
        self.assertEqual(result.returncode, 1)

    def test_player_dies_when_owner_is_killed(self):
        code = '''import os, subprocess, sys
p = subprocess.Popen([sys.executable, sys.argv[1], str(os.getpid()),
                      sys.executable, "-c", "import os,time; print(os.getpid(), flush=True); time.sleep(60)"])
p.wait()
'''
        with subprocess.Popen([sys.executable, "-c", code, str(LAUNCHER)],
                              stdout=subprocess.PIPE, text=True) as owner:
            pid = int(owner.stdout.readline())
            try:
                owner.kill()
                owner.wait(timeout=5)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        state = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][0]
                    except FileNotFoundError:
                        return
                    if state == "Z":
                        return
                    time.sleep(0.02)
                self.fail("player survived owner death")
            finally:
                if owner.poll() is None:
                    owner.kill()
                # A failed assertion must not leave the test child running.
                try:
                    if Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][0] != "Z":
                        os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except FileNotFoundError:
                    pass


if __name__ == "__main__":
    unittest.main()
