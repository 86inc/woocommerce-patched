#!/usr/bin/env bash
#
# Print a short hash identifying the current patch set (patch files, in manifest order).
#
# Usage: bin/patch-set-hash.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if command -v sha256sum >/dev/null 2>&1; then
	hasher=(sha256sum)
else
	hasher=(shasum -a 256)
fi

jq -r '.patches[].file' "$ROOT/patches.json" \
	| while read -r file; do cat "$ROOT/$file"; done \
	| "${hasher[@]}" | cut -c1-12
