#!/usr/bin/env bash
#
# Turn the drift review's structured result into an issue and a risk level.
#
# Usage: bin/drift-report.sh
#
# Env:
#   TAG, PREVIOUS   The reviewed tag range.
#   CHANGED         "true" when any watched upstream file changed.
#   REVIEW_OUTCOME  Outcome of the review job ("success" or otherwise).
#   RESULT          The review's structured output (JSON), possibly empty.
#   DRIFT_MODE      "hold" to hold releases on high risk; anything else is report-only.
#   GH_TOKEN, GITHUB_REPOSITORY, MAINTAINER, RUN_URL.
#
# Prints risk=none|low|high|error (for $GITHUB_OUTPUT). Opens or comments on
# "Drift review: WooCommerce <tag>" when there are findings or the review failed.

set -euo pipefail

title="Drift review: WooCommerce $TAG"

if [ "${CHANGED:-}" != "true" ]; then
	echo "No upstream changes in watched files between $PREVIOUS and $TAG." >&2
	echo "risk=none"
	exit 0
fi

risk="error"
findings="[]"
if [ "${REVIEW_OUTCOME:-}" = "success" ] && jq -e '.risk and (.findings | type == "array")' >/dev/null 2>&1 <<<"${RESULT:-}"; then
	risk="$(jq -r '.risk' <<<"$RESULT")"
	findings="$(jq -c '.findings' <<<"$RESULT")"
fi
case "$risk" in
	none | low | high | error) ;;
	*) risk="error" ;;
esac

if [ "$risk" = "none" ] && [ "$findings" = "[]" ]; then
	echo "Drift review found no risk between $PREVIOUS and $TAG." >&2
	echo "risk=none"
	exit 0
fi

if [ "$risk" = "error" ]; then
	effect="The review did not finish (Claude Code may have hit a usage limit), so it had no effect on the release."
elif [ "$risk" = "high" ] && [ "${DRIFT_MODE:-}" = "hold" ]; then
	effect="**The release is held.** After checking, release anyway with \`gh workflow run build-release.yml -R $GITHUB_REPOSITORY -f tag=$TAG -f skip_drift=true\`."
else
	effect="Report-only: the release was not held."
fi

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
{
	echo "Drift review of upstream changes \`$PREVIOUS\` → \`$TAG\`: **$risk** risk. $effect See [the run]($RUN_URL)."
	if [ "$findings" != "[]" ]; then
		echo
		echo "| Patch | Severity | File | Finding |"
		echo "| ----- | -------- | ---- | ------- |"
		# Findings are model output: keep each cell on one line and pipes escaped.
		jq -r '.[] | [.patch, .severity, .file, .summary]
			| map(tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|"))
			| "| `\(.[0])` | \(.[1]) | `\(.[2])` | \(.[3]) |"' <<<"$findings"
	fi
} > "$body"

cat "$body" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

existing="$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --author app/github-actions \
	--search "\"$title\" in:title" --json number,title \
	| jq -r --arg title "$title" '.[] | select(.title == $title) | .number' | head -1)"
if [ -n "$existing" ]; then
	gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body-file "$body" >&2
else
	gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$body" --assignee "$MAINTAINER" >&2
fi

echo "risk=$risk"
