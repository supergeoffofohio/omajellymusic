from __future__ import annotations

import argparse
import sys
from pathlib import Path

from omajelly.commands import print_json
from omajelly.common import (
    ConfigurationError,
    JellyfinError,
    clean_text,
    wall_deadline,
)
from omajelly.connection import (
    clear_configuration,
    configure_connection,
    configure_from_env,
    read_setup,
    status_document,
)
from omajelly.quickconnect import (
    cancel_quick_connect,
    poll_quick_connect,
    start_quick_connect,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="omajelly")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("configure")
    commands.add_parser("clear-configuration")
    quick_start = commands.add_parser("quick-connect-start")
    quick_start.add_argument("--server", required=True)
    commands.add_parser("quick-connect-poll")
    commands.add_parser("quick-connect-cancel")
    configure = commands.add_parser("configure-from-env")
    configure.add_argument("env_file")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "status":
            print_json(status_document())
            return 0
        if args.command == "configure":
            setup = read_setup()
            with wall_deadline(30, "Jellyfin setup exceeded thirty seconds"):
                print_json(configure_connection(setup))
            return 0
        if args.command == "quick-connect-start":
            with wall_deadline(20, "Quick Connect could not be started"):
                print_json(start_quick_connect(args.server))
            return 0
        if args.command == "quick-connect-poll":
            with wall_deadline(20, "Quick Connect check timed out"):
                print_json(poll_quick_connect())
            return 0
        if args.command == "quick-connect-cancel":
            print_json(cancel_quick_connect())
            return 0
        if args.command == "clear-configuration":
            print_json(clear_configuration())
            return 0
        if args.command == "configure-from-env":
            with wall_deadline(25, "Jellyfin setup exceeded twenty-five seconds"):
                print_json(configure_from_env(Path(args.env_file)))
            return 0
        raise ConfigurationError("Unknown command")
    except JellyfinError as error:
        print(clean_text(error, 220), file=sys.stderr)
        return 2
    except Exception:  # noqa: BLE001 - CLI boundary hides internal tracebacks
        print("The Jellyfin helper failed unexpectedly", file=sys.stderr)
        return 2
