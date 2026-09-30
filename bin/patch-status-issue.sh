#!/usr/bin/env bash
#
# Keep the "Patch status" issue in sync with bin/patch-status.sh output.
#
# Usage: bin/patch-status-issue.sh <status.json>
#
# Rewrites the issue's status table on every run (editing the body sends no
# notification), and comments only for patches whose status changed since the last
# run, so the maintainer is emailed once per change.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, MAINTAINER, and optionally RETIRE_COMMIT (the
# commit that marked newly shipped patches).

set -euo pipefail

STATUS_FILE="${1:-}"
if [ ! -f "$STATUS_FILE" ]; then
	echo "Usage: bin/patch-status-issue.sh <status.json>" >&2
	exit 1
fi

TITLE="Patch status"
MARKER_PREFIX="<!-- patch-status: "
MARKER_SUFFIX=" -->"
REPO="$GITHUB_REPOSITORY"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

# One comparable string per patch: status, plus the PR head for `updated`.
current_state="$(jq -c 'map({key: .id, value: (.status + (if .status == "updated" then ":" + .head else "" end))}) | from_entries' "$STATUS_FILE")"

describe() {
	jq -r '.[] | "| `\(.id)` | \(if .pr then "[#\(.pr)](\(.url // ""))" else "local" end) | \(
		if .status == "open" then "Open, matches our pinned commit"
		elif .status == "updated" then "Open, with commits after our pinned commit"
		elif .status == "merged" then "Merged, not in a stable release yet"
		elif .status == "shipped" then "Shipped in \(.shipped_in); skipped from then on"
		elif .status == "closed" then "Closed without merging"
		else "Local patch" end) |"' "$STATUS_FILE"
}

{
	echo "The upstream PR behind each patch, checked daily by [patch-status.yml]($SERVER/$REPO/actions/workflows/patch-status.yml). Status changes are posted as comments."
	echo
	echo "| Patch | Upstream | Status |"
	echo "| ----- | -------- | ------ |"
	describe
	echo
	echo "Last checked $(date -u '+%Y-%m-%d %H:%M UTC')."
	echo
	echo "$MARKER_PREFIX$current_state$MARKER_SUFFIX"
} > "$BODY"

number="$(gh issue list --repo "$REPO" --state open --author app/github-actions \
	--search "\"$TITLE\" in:title" --json number,title \
	| jq -r --arg title "$TITLE" '.[] | select(.title == $title) | .number' | head -1)"

if [ -z "$number" ]; then
	gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY" --assignee "$MAINTAINER"
	exit 0
fi

previous_state="{}"
while IFS= read -r line; do
	case "$line" in
		"$MARKER_PREFIX"*)
			line="${line#"$MARKER_PREFIX"}"
			previous_state="${line%"$MARKER_SUFFIX"}"
			;;
	esac
done < <(gh issue view "$number" --repo "$REPO" --json body --jq .body)
jq -e . >/dev/null 2>&1 <<<"$previous_state" || previous_state="{}"

gh issue edit "$number" --repo "$REPO" --body-file "$BODY" >/dev/null

changes="$(jq -r --argjson prev "$previous_state" --argjson cur "$current_state" \
	'.[] | select($prev[.id] != null and $prev[.id] != $cur[.id]) | @base64' "$STATUS_FILE")"

comment=""
while read -r encoded; do
	[ -n "$encoded" ] || continue
	patch="$(base64 --decode <<<"$encoded")"
	id="$(jq -r .id <<<"$patch")"
	pr="$(jq -r .pr <<<"$patch")"
	case "$(jq -r .status <<<"$patch")" in
		updated)
			line="PR #$pr has new commits (head \`$(jq -r '.head[0:10]' <<<"$patch")\`) after our pinned commit. If they matter, re-export \`$id\` and update \`pinned_commit\`."
			;;
		merged)
			line="PR #$pr was merged upstream. \`$id\` is retired automatically once a stable release includes it."
			;;
		shipped)
			line="PR #$pr shipped in WooCommerce $(jq -r .shipped_in <<<"$patch"). \`$id\` is now marked \`shipped_in\`, so builds of that version and later skip it${RETIRE_COMMIT:+ ($SERVER/$REPO/commit/$RETIRE_COMMIT)}. Delete it once older versions are no longer built."
			;;
		closed)
			line="PR #$pr was closed without merging. \`$id\` keeps being applied; decide whether to keep it as a local patch."
			;;
		open)
			line="\`$id\` matches the head of PR #$pr again."
			;;
		*)
			continue
			;;
	esac
	comment+="- $line"$'\n'
done <<<"$changes"

if [ -n "$comment" ]; then
	printf '%s' "$comment" | gh issue comment "$number" --repo "$REPO" --body-file -
	gh issue edit "$number" --repo "$REPO" --add-assignee "$MAINTAINER" >/dev/null
fi
