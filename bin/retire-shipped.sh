#!/usr/bin/env bash
#
# Mark patches that bin/patch-status.sh found newly shipped with `shipped_in`.
#
# Usage: bin/retire-shipped.sh <status.json>
#
# Prints "<id> <version>" for each patch it marked. Builds of that version and
# later then skip the patch; its files stay so older versions can still be rebuilt.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
STATUS_FILE="${1:-}"
if [ ! -f "$STATUS_FILE" ]; then
	echo "Usage: bin/retire-shipped.sh <status.json>" >&2
	exit 1
fi

while read -r id version; do
	[ -n "$id" ] || continue
	# Tags reach here from the upstream release list; keep them to version characters.
	if [ -n "$(tr -d '0-9A-Za-z.-' <<<"$version")" ]; then
		echo "Skipping $id: unexpected version '$version'" >&2
		continue
	fi
	updated="$(jq --tab --arg id "$id" --arg v "$version" \
		'(.patches[] | select(.id == $id and (.shipped_in // "") == "")).shipped_in = $v' "$MANIFEST")"
	printf '%s\n' "$updated" > "$MANIFEST"
	echo "$id $version"
done < <(jq -r '.[] | select(.newly_shipped == true) | "\(.id) \(.shipped_in)"' "$STATUS_FILE")
