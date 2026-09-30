#!/usr/bin/env bash
#
# Export a manifest patch from its upstream PR commit.
#
# Usage: bin/export-patch.sh <patch-id> [--force]
#
# Diffs `base_commit..pinned_commit` from the manifest, limited to files that
# ship in or test the plugin (changelog entries and docs are left out).
#
# Env:
#   WC_SOURCE_REPO  Local WooCommerce monorepo checkout (default: ../woocommerce).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
SOURCE_REPO="${WC_SOURCE_REPO:-$ROOT/../woocommerce}"

PATCH_ID="${1:-}"
if [ -z "$PATCH_ID" ]; then
	echo "Usage: bin/export-patch.sh <patch-id>" >&2
	exit 1
fi

entry="$(jq -c --arg id "$PATCH_ID" '.patches[] | select(.id == $id)' "$MANIFEST")"
if [ -z "$entry" ]; then
	echo "No patch with id '$PATCH_ID' in patches.json" >&2
	exit 1
fi

head_repo="$(jq -r '.head_repo' <<<"$entry")"
head_ref="$(jq -r '.head_ref' <<<"$entry")"
pinned_commit="$(jq -r '.pinned_commit' <<<"$entry")"
base_commit="$(jq -r '.base_commit' <<<"$entry")"
out_file="$ROOT/$(jq -r '.file' <<<"$entry")"
refreshed_on="$(jq -r '.refreshed_on // empty' <<<"$entry")"

if [ -n "$refreshed_on" ] && [ "${2:-}" != "--force" ]; then
	echo "$PATCH_ID was refreshed on $refreshed_on; exporting from the PR would discard that." >&2
	echo "Re-run with --force to overwrite it anyway." >&2
	exit 1
fi

for commit in "$pinned_commit" "$base_commit"; do
	if ! git -C "$SOURCE_REPO" cat-file -e "$commit^{commit}" 2>/dev/null; then
		echo "Fetching $commit from $head_repo..."
		git -C "$SOURCE_REPO" fetch --quiet "https://github.com/$head_repo.git" "$head_ref" || true
		git -C "$SOURCE_REPO" cat-file -e "$commit^{commit}"
	fi
done

mkdir -p "$(dirname "$out_file")"
git -C "$SOURCE_REPO" diff --binary --full-index "$base_commit" "$pinned_commit" -- \
	plugins/woocommerce \
	':(exclude)plugins/woocommerce/changelog' \
	> "$out_file"

echo "Wrote ${out_file#"$ROOT/"} ($(git -C "$SOURCE_REPO" diff --name-only "$base_commit" "$pinned_commit" -- plugins/woocommerce ':(exclude)plugins/woocommerce/changelog' | wc -l | tr -d ' ') files)"
