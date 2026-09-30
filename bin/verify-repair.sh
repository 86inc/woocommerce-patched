#!/usr/bin/env bash
#
# Check patches produced by the repair agent, then install them into this checkout.
#
# Usage: bin/verify-repair.sh <candidate-dir>
#
# <candidate-dir> holds the agent's patches.json and patches/. Accepted only when:
#   - patches.json differs from this checkout's only in `refreshed_on` values.
#   - Every file a patch touches is inside that patch's `allowed_paths`, read from
#     this checkout's manifest, not the candidate's.
#   - No patch contains binary data, mode changes, or symlinks.
# Only the .patch files listed in the manifest are copied; anything else in the
# candidate directory is ignored.
#
# Prints the ids of the patches that changed, one per line.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
CANDIDATE="${1:-}"
if [ -z "$CANDIDATE" ] || [ ! -f "$CANDIDATE/patches.json" ]; then
	echo "Usage: bin/verify-repair.sh <candidate-dir> (with patches.json and patches/)" >&2
	exit 1
fi

fail() {
	echo "Rejected: $*" >&2
	exit 1
}

without_refresh='del(.patches[].refreshed_on)'
if ! jq -e --slurpfile candidate "$CANDIDATE/patches.json" \
	"($without_refresh) == (\$candidate[0] | $without_refresh)" "$MANIFEST" >/dev/null; then
	fail "patches.json changed beyond refreshed_on"
fi

# Prints both paths of every `diff --git a/<old> b/<new>` header.
touched_paths() {
	awk 'index($0, "diff --git a/") == 1 {
		split($0, parts, " ")
		print substr(parts[3], 3)
		print substr(parts[4], 3)
	}' "$1" | sort -u
}

changed=()
while IFS=$'\t' read -r id file; do
	candidate_file="$CANDIDATE/$file"
	[ -f "$candidate_file" ] || fail "$file is missing"
	if cmp -s "$candidate_file" "$ROOT/$file"; then
		continue
	fi

	forbidden="$(awk 'index($0, "GIT binary patch") == 1 || index($0, "old mode ") == 1 \
		|| index($0, "new mode ") == 1 || index($0, "new file mode 120000") == 1 \
		|| index($0, "deleted file mode 120000") == 1' "$candidate_file")"
	[ -z "$forbidden" ] || fail "$file contains binary data, a mode change, or a symlink"

	paths="$(touched_paths "$candidate_file")"
	[ -n "$paths" ] || fail "$file touches no files"

	allowed="$(jq -r --arg id "$id" '.patches[] | select(.id == $id) | .allowed_paths[]' "$MANIFEST")"
	while read -r path; do
		ok=0
		while read -r prefix; do
			case "$path" in
				"$prefix"*) ok=1; break ;;
			esac
		done <<<"$allowed"
		[ "$ok" -eq 1 ] || fail "$file touches $path, outside the allowed_paths of $id"
	done <<<"$paths"

	changed+=( "$id" )
done < <(jq -r '.patches[] | [.id, .file] | @tsv' "$MANIFEST")

[ "${#changed[@]}" -gt 0 ] || fail "no patch changed"

while IFS=$'\t' read -r _ file; do
	cp "$CANDIDATE/$file" "$ROOT/$file"
done < <(jq -r '.patches[] | [.id, .file] | @tsv' "$MANIFEST")
cp "$CANDIDATE/patches.json" "$MANIFEST"

printf '%s\n' "${changed[@]}"
