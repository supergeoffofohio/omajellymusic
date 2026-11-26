"""Linux child launcher: ensure an exec'd player cannot outlive its owner."""
import ctypes
import os
import signal
import sys


def main():
    parent_pid = int(sys.argv[1])
    command = sys.argv[2:]
    # Do this in the child, not a Popen preexec_fn (the owner may have threads).
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
        raise OSError(ctypes.get_errno(), "Could not set player parent-death signal")
    # The owner might have died between fork and prctl.
    if os.getppid() != parent_pid:
        return 1
    os.execvp(command[0], command)


if __name__ == "__main__":
    raise SystemExit(main())
