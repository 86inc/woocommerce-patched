#!/usr/bin/env bash
#
# Rerun the build, tests, and smoke test for a tag and record what failed, so the
# repair agent starts from the failing state.
#
# Usage: bin/diagnose.sh <tag>
#
# Prints key=value lines (for $GITHUB_OUTPUT), with progress on stderr:
#   mode   none | conflict | merged-upstream | build | tests | smoke | setup
#   patch  The conflicting patch id (conflict and merged-upstream modes).
#
# For every mode the agent can act on, writes <work root>/repair/TASK.md (from
# ai/repair-task.md) and the failing step's output to <work root>/repair/failure.log.
# `setup` means the environment broke before any patch code ran, and
# `merged-upstream` that the conflicting patch's PR is merged; neither starts the agent.
#
# Env: GH_TOKEN (for the upstream PR lookup).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"
TAG="${1:-}"
if [ -z "$TAG" ]; then
	echo "Usage: bin/diagnose.sh <tag>" >&2
	exit 1
fi

REPAIR_DIR="$WORK_ROOT/repair"
LOG="$REPAIR_DIR/failure.log"
mkdir -p "$REPAIR_DIR"
rm -f "$REPAIR_DIR/TASK.md" "$REPAIR_DIR/SUMMARY.md" "$LOG"

# Runs a step, keeping only its output in failure.log. Returns the step's exit code.
run_step() {
	"$@" 2>&1 | tee "$LOG" >&2
	return "${PIPESTATUS[0]}"
}

write_task() {
	local mode="$1" patch="$2" task
	task="$(cat "$ROOT/ai/repair-task.md")"
	task="${task//\{\{TAG\}\}/$TAG}"
	task="${task//\{\{MODE\}\}/$mode}"
	task="${task//\{\{PATCH_ID\}\}/$patch}"
	task="${task//\{\{WORK\}\}/$WORK_ROOT/$TAG}"
	task="${task//\{\{REPAIR_DIR\}\}/$REPAIR_DIR}"
	printf '%s\n' "$task" > "$REPAIR_DIR/TASK.md"
}

finish() {
	local mode="$1" patch="${2:-}"
	if [ "$mode" != "none" ] && [ "$mode" != "setup" ] && [ "$mode" != "merged-upstream" ]; then
		write_task "$mode" "$patch"
	fi
	echo "mode=$mode"
	echo "patch=$patch"
	exit 0
}

run_step "$ROOT/bin/build.sh" "$TAG" --fresh
case "$?" in
	0) ;;
	2)
		patch="$(jq -r '[.patches[] | select(.status == "conflict")][0].id' "$WORK_ROOT/$TAG.report.json")"
		pr="$(jq -r --arg id "$patch" '.patches[] | select(.id == $id) | .upstream_pr // empty' "$ROOT/patches.json")"
		upstream="$(jq -r '.upstream_repo' "$ROOT/patches.json")"
		# A merged PR usually conflicts because upstream shipped a reviewed version of
		# it; retiring the patch (patch-status.yml) is the fix, not an AI rewrite.
		if [ -n "$pr" ] && [ "$(gh api "repos/$upstream/pulls/$pr" --jq .merged 2>/dev/null)" = "true" ]; then
			finish merged-upstream "$patch"
		fi
		finish conflict "$patch"
		;;
	3) finish build ;;
	*) finish setup ;;
esac

run_step "$ROOT/bin/test.sh" "$TAG"
case "$?" in
	0) ;;
	4) finish tests ;;
	*) finish setup ;;
esac

run_step "$ROOT/bin/smoke-test.sh" "$TAG"
case "$?" in
	0) finish none ;;
	4) finish smoke ;;
	*) finish setup ;;
esac
