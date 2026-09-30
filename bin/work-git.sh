#!/usr/bin/env bash
#
# Read-only git commands in a build work directory, for the repair agent.
#
# Usage: bin/work-git.sh <tag> <status|diff|log|show|ls-files|grep> [args...]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"
TAG="${1:-}"
SUBCOMMAND="${2:-}"

case "$SUBCOMMAND" in
	status | diff | log | show | ls-files | grep) ;;
	*)
		echo "Usage: bin/work-git.sh <tag> <status|diff|log|show|ls-files|grep> [args...]" >&2
		exit 1
		;;
esac
shift 2

for arg in "$@"; do
	case "$arg" in
		--output* | --ext-diff | --textconv | -O*)
			echo "Option not allowed: $arg" >&2
			exit 1
			;;
	esac
done

exec git -C "$WORK_ROOT/$TAG" --no-pager -c core.pager=cat -c diff.external= "$SUBCOMMAND" "$@"
