#!/usr/bin/env bash
#
# Save changes made in a build work directory as a fix to one patch.
#
# Usage: bin/save-resolution.sh <tag> <patch-id>
#
# Takes every uncommitted change in .work/<tag> (resolved conflicts, new or edited
# files) and folds it into that patch's "Apply patch: <id>" commit, creating the
# commit if the patch never applied. Then re-exports the patch with save-patch.sh.
#
# Refuses, leaving the work directory untouched, when a change is outside the
# patch's `allowed_paths` or still contains conflict markers.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"

TAG="${1:-}"
PATCH_ID="${2:-}"
if [ -z "$TAG" ] || [ -z "$PATCH_ID" ]; then
	echo "Usage: bin/save-resolution.sh <tag> <patch-id>" >&2
	exit 1
fi

WORK="$WORK_ROOT/$TAG"
if [ ! -d "$WORK/.git" ]; then
	echo "No work directory at $WORK. Run bin/build.sh $TAG --fresh --apply-only first." >&2
	exit 1
fi

allowed="$(jq -r --arg id "$PATCH_ID" '.patches[] | select(.id == $id) | .allowed_paths[]' "$MANIFEST")"
if [ -z "$allowed" ]; then
	echo "No patch with id '$PATCH_ID' (or no allowed_paths) in patches.json" >&2
	exit 1
fi

git_work() {
	git -C "$WORK" -c user.name="86inc build" -c user.email="build@86inc.invalid" "$@"
}

git_work add -A
changed="$(git_work diff --cached --name-only)"
if [ -z "$changed" ]; then
	echo "No changes to save in $WORK" >&2
	exit 1
fi

outside=""
while read -r path; do
	ok=0
	while read -r prefix; do
		case "$path" in
			"$prefix"*) ok=1; break ;;
		esac
	done <<<"$allowed"
	if [ "$ok" -eq 0 ]; then
		outside+="  $path"$'\n'
	fi
done <<<"$changed"

markers="$(git_work diff --cached | awk 'index($0, "+<<<<<<<") == 1 || index($0, "+>>>>>>>") == 1')"

if [ -n "$outside" ] || [ -n "$markers" ]; then
	git_work reset --quiet
	if [ -n "$outside" ]; then
		printf 'Changes outside the allowed_paths of %s:\n%s' "$PATCH_ID" "$outside" >&2
		printf 'Allowed:\n%s\n' "$allowed" | sed 's/^/  /' >&2
	fi
	if [ -n "$markers" ]; then
		echo "Conflict markers are still present:" >&2
		echo "$markers" >&2
	fi
	exit 1
fi

apply_commit="$(git_work log --format=%H --fixed-strings --grep="Apply patch: $PATCH_ID" -1)"
if [ -z "$apply_commit" ]; then
	git_work commit --quiet -m "Apply patch: $PATCH_ID"
else
	git_work commit --quiet --fixup="$apply_commit"
	if ! GIT_SEQUENCE_EDITOR=: git_work rebase --quiet -i --autosquash "$apply_commit^"; then
		git_work rebase --abort
		echo "Could not fold the fix into 'Apply patch: $PATCH_ID' (a later commit conflicts with it)." >&2
		exit 1
	fi
fi

"$ROOT/bin/save-patch.sh" "$TAG" "$PATCH_ID"
