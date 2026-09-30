#!/usr/bin/env bash
#
# Prepare the drift review: the upstream diff between two tags, limited to what
# each patch touches or watches.
#
# Usage: bin/drift-context.sh <previous-tag> <tag>
#
# Writes to <work root>/drift/:
#   src/        Checkout of <tag> (for the reviewer to search).
#   <id>.diff   Upstream changes in the patch's files and `watch_paths`, capped at
#               MAX_LINES lines (a --stat summary is always included).
#   TASK.md     The review task (from ai/drift-review.md).
# Patches skipped for <tag> (`shipped_in`, `min_version`) are left out.
#
# Prints key=value lines (for $GITHUB_OUTPUT): changed=true|false.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"
UPSTREAM="$(jq -r '.upstream_repo' "$MANIFEST")"
MAX_LINES=4000

PREVIOUS="${1:-}"
TAG="${2:-}"
if [ -z "$PREVIOUS" ] || [ -z "$TAG" ]; then
	echo "Usage: bin/drift-context.sh <previous-tag> <tag>" >&2
	exit 1
fi
# The previous tag can come from a workflow input; keep both to version characters.
for ref in "$PREVIOUS" "$TAG"; do
	if [ -n "$(tr -d '0-9A-Za-z.-' <<<"$ref")" ]; then
		echo "Invalid tag: '$ref'" >&2
		exit 1
	fi
done

DRIFT="$WORK_ROOT/drift"
SRC="$DRIFT/src"
rm -rf "$DRIFT"
mkdir -p "$DRIFT"

# Same rule as build.sh: pre-release suffixes are ignored.
version_lt() {
	local a="${1%%-*}" b="${2%%-*}"
	[ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$a" ]
}

git init --quiet "$SRC"
git -C "$SRC" remote add origin "https://github.com/$UPSTREAM.git"
git -C "$SRC" fetch --quiet --filter=blob:none --depth 1 origin \
	"refs/tags/$PREVIOUS:refs/tags/$PREVIOUS" "refs/tags/$TAG:refs/tags/$TAG"
git -C "$SRC" -c advice.detachedHead=false checkout --quiet "tags/$TAG"

reviewed=()
while IFS=$'\x1f' read -r id file min_version shipped_in; do
	if { [ -n "$min_version" ] && version_lt "$TAG" "$min_version"; } \
		|| { [ -n "$shipped_in" ] && ! version_lt "$TAG" "$shipped_in"; }; then
		continue
	fi

	paths=()
	while read -r path; do
		[ -n "$path" ] && paths+=( "$path" )
	done < <(
		awk 'index($0, "diff --git a/") == 1 { split($0, parts, " "); print substr(parts[4], 3) }' "$ROOT/$file"
		jq -r --arg id "$id" '.patches[] | select(.id == $id) | .watch_paths[]?' "$MANIFEST"
	)

	out="$DRIFT/$id.diff"
	stat="$(git -C "$SRC" diff --stat=200 "tags/$PREVIOUS" "tags/$TAG" -- "${paths[@]}")"
	if [ -z "$stat" ]; then
		continue
	fi
	full="$DRIFT/$id.full"
	git -C "$SRC" diff "tags/$PREVIOUS" "tags/$TAG" -- "${paths[@]}" > "$full"
	{
		echo "# Upstream changes $PREVIOUS..$TAG in files patch $id touches or watches"
		echo
		echo "$stat"
		echo
		head -n "$MAX_LINES" "$full"
		if [ "$(wc -l < "$full")" -gt "$MAX_LINES" ]; then
			printf '\n# Diff truncated at %s lines; read the full files in %s.\n' "$MAX_LINES" "$SRC"
		fi
	} > "$out"
	rm -f "$full"
	reviewed+=( "$id" )
done < <(jq -r '.patches[] | [.id, .file, .min_version // "", .shipped_in // ""] | join("\u001f")' "$MANIFEST")

if [ "${#reviewed[@]}" -eq 0 ]; then
	echo "changed=false"
	exit 0
fi

list=""
for id in "${reviewed[@]}"; do
	list+="- \`$id\`: \`$DRIFT/$id.diff\`"$'\n'
done
task="$(cat "$ROOT/ai/drift-review.md")"
task="${task//\{\{PREVIOUS\}\}/$PREVIOUS}"
task="${task//\{\{TAG\}\}/$TAG}"
task="${task//\{\{SRC\}\}/$SRC}"
task="${task//\{\{DIFFS\}\}/$list}"
printf '%s\n' "$task" > "$DRIFT/TASK.md"

echo "changed=true"
