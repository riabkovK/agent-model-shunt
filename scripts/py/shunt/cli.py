"""Command line entry: argparse subcommands dispatched from shunt_main.py."""

import argparse
from collections.abc import Sequence

from . import (breaker, breaker_config_cli, bulk_read, code_write, codewrite_config_cli, context_detect, cw_cli, dashboard, failover, healthcheck_bg, migrate, models, models_cli,
               models_write, opencode_cli, orchestrator, probe, providers, providers_write, selffix, transport, usage_log, usage_report)
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
    breaker.register(sub)
    transport.register(sub)
    failover.register(sub)
    usage_log.register(sub)
    opencode_cli.register(sub)
    cw_cli.register(sub)
    selffix.register(sub)
    orchestrator.register(sub)
    probe.register(sub)
    healthcheck_bg.register(sub)
    dashboard.register(sub)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    if argv and argv[0] == bulk_read.COMMAND:  # the script's own arguments, argparse must not see them
        return bulk_read.main(argv[1:])
    if argv and argv[0] == code_write.COMMAND:  # same: --spec takes any word, even one starting with --
        return code_write.main(argv[1:])
    if argv and argv[0] == usage_report.COMMAND:
        return usage_report.main(argv[1:] if argv[1:2] != ["--"] else argv[2:])
    if argv and argv[0] == breaker_config_cli.COMMAND:
        return breaker_config_cli.main(argv[1:] if argv[1:2] != ["--"] else argv[2:])
    if argv and argv[0] == codewrite_config_cli.COMMAND:
        return codewrite_config_cli.main(argv[1:] if argv[1:2] != ["--"] else argv[2:])
    if argv and argv[0] == models_cli.COMMAND:  # user words such as --clear or a JSON body are data, not options
        return models_cli.main(argv[1:] if argv[1:2] != ["--"] else argv[2:])
    args = build_parser().parse_args(argv)
    return args.func(args)
