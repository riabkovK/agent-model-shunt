"""Command line entry: argparse subcommands dispatched from shunt_main.py."""

import argparse
from collections.abc import Sequence

from . import context_detect, migrate, models, models_write, providers, providers_write
from .version import plugin_version


def _cmd_version(_args: argparse.Namespace) -> int:
    print(plugin_version())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="shunt_main.py")
    sub = parser.add_subparsers(dest="command", required=True)
    version = sub.add_parser("version", help="print the plugin version")
    version.set_defaults(func=_cmd_version)
    models.register(sub)
    providers.register(sub)
    context_detect.register(sub)
    models_write.register(sub)
    providers_write.register(sub)
    migrate.register(sub)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)
