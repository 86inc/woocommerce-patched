#!/usr/bin/env bash
#
# Run the unit tests the manifest lists for each patch, in a built work directory.
#
# Usage: bin/test.sh <tag> [--jest-only]
#
# Expects bin/build.sh <tag> to have run (dependencies installed in .work/<tag>).
# PHPUnit runs on the monorepo's own wp-env test environment (.wp-env.test.json).
#
# Exit codes: 0 pass, 1 usage/setup error, 4 test failure.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"

TAG=""
JEST_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--jest-only) JEST_ONLY=1 ;;
		-*) echo "Unknown option: $arg" >&2; exit 1 ;;
		*) TAG="$arg" ;;
	esac
done
if [ -z "$TAG" ]; then
	echo "Usage: bin/test.sh <tag> [--jest-only]" >&2
	exit 1
fi

WORK="$WORK_ROOT/$TAG"
PLUGIN="$WORK/plugins/woocommerce"
BLOCKS="$PLUGIN/client/blocks"
if [ ! -d "$BLOCKS/node_modules" ]; then
	echo "No installed build in ${WORK#"$ROOT/"}. Run bin/build.sh $TAG first." >&2
	exit 1
fi

log() { printf '\n==> %s\n' "$*"; }

# Jest paths are relative to the Blocks package, where its Jest config lives.
jest_paths=()
while read -r path; do
	jest_paths+=( "${path#plugins/woocommerce/client/blocks/}" )
done < <(jq -r '[.patches[].tests.jest[]?] | unique | .[]' "$MANIFEST")

if [ "${#jest_paths[@]}" -gt 0 ]; then
	log "Jest: ${#jest_paths[@]} suite(s)"
	(cd "$BLOCKS" && corepack pnpm test:js -- "${jest_paths[@]}") || exit 4
fi

if [ "$JEST_ONLY" -eq 1 ]; then
	exit 0
fi

phpunit_filter="$(jq -r '[.patches[].tests.phpunit[]?] | unique | join("|")' "$MANIFEST")"
if [ -n "$phpunit_filter" ]; then
	log "PHPUnit: $phpunit_filter"
	# build.sh leaves production-only PHP dependencies; PHPUnit needs the dev ones.
	(cd "$PLUGIN" && composer install --quiet) || exit 1

	local_attempt=1
	until (cd "$PLUGIN" && corepack pnpm wp-env:test start); do
		if [ "$local_attempt" -eq 3 ]; then
			echo "wp-env test environment failed to start after 3 attempts." >&2
			exit 1
		fi
		echo "wp-env start failed (attempt $local_attempt), retrying..."
		local_attempt=$((local_attempt + 1))
		sleep 10
	done

	(cd "$PLUGIN" && corepack pnpm test:php:env -- --filter "($phpunit_filter)") || exit 4
fi

echo
echo "Tests passed."
