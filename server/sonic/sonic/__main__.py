"""`python -m sonic serve` runs the service; `python -m sonic compare-plex` checks it."""

from __future__ import annotations

import argparse
import logging
import threading

from .config import Config


def main() -> None:
    parser = argparse.ArgumentParser(prog="sonic")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("serve", help="sync, analyse and answer, forever")
    compare = commands.add_parser("compare-plex", help="how close our vectors are to the ones Plex stored")
    compare.add_argument("--plex-db", required=True, help="com.plexapp.plugins.library.db")
    compare.add_argument("--analysis", required=True, nargs="+", help="'Music Analysis <n>' directories")
    compare.add_argument("--plex-root", default="/media", help="Plex's path for the media root")
    compare.add_argument("--local-root", default="/mnt/hdd-pool-media", help="the same root here")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    config = Config()

    if args.command == "serve":
        from .http import serve
        from .service import Service

        service = Service(config)
        threading.Thread(target=service.run_forever, name="analysis", daemon=True).start()
        serve(service)
    elif args.command == "compare-plex":
        from .plexcheck import report

        report(config, args.plex_db, args.analysis, args.plex_root, args.local_root)


if __name__ == "__main__":
    main()
