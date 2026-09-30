#!/usr/bin/env bash
#
# Save a patch refreshed in a build work directory back into patches/.
#
# Usage: bin/save-patch.sh <tag> <patch-id>
#
# Expects the patch's changes committed in .work/<tag> as "Apply patch: <id>",
# which build.sh does for clean applies. After resolving a conflict, stage the
# resolution and run `git commit -m "Apply patch: <id>"` there first.
# Records the tag in the manifest's `refreshed_on` so the file's origin is clear.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"

TAG="${1:-}"
PATCH_ID="${2:-}"
if [ -z "$TAG" ] || [ -z "$PATCH_ID" ]; then
	echo "Usage: bin/save-patch.sh <tag> <patch-id>" >&2
	exit 1
fi

WORK="$WORK_ROOT/$TAG"
out_file="$ROOT/$(jq -r --arg id "$PATCH_ID" '.patches[] | select(.id == $id) | .file' "$MANIFEST")"
if [ "$out_file" = "$ROOT/" ]; then
	echo "No patch with id '$PATCH_ID' in patches.json" >&2
	exit 1
fi

commit="$(git -C "$WORK" log --format=%H --fixed-strings --grep="Apply patch: $PATCH_ID" -1)"
if [ -z "$commit" ]; then
	echo "No 'Apply patch: $PATCH_ID' commit in $WORK" >&2
	exit 1
fi

git -C "$WORK" diff --binary --full-index "$commit^" "$commit" > "$out_file"

updated="$(jq --tab --arg id "$PATCH_ID" --arg tag "$TAG" \
	'(.patches[] | select(.id == $id)).refreshed_on = $tag' "$MANIFEST")"
printf '%s\n' "$updated" > "$MANIFEST"

echo "Saved ${out_file#"$ROOT/"} from $TAG ($(git -C "$WORK" diff --name-only "$commit^" "$commit" | wc -l | tr -d ' ') files)"
