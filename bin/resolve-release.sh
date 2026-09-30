#!/usr/bin/env bash
#
# Decide what the release workflow should build.
#
# Usage: bin/resolve-release.sh [tag] [force]
#
#   tag    Upstream tag to build (default: latest stable upstream release).
#   force  "true" to rebuild even if a release exists for this tag and patch set.
#
# Prints key=value lines (for $GITHUB_OUTPUT):
#   tag          Upstream tag.
#   build        Build stamp, <tag>+<patch-set-hash>.
#   release_tag  Our release tag, <tag>-build.<n>.
#   is_latest    "true" when tag is the latest stable upstream release.
#   skip         "true" when a release for this build already exists.
#
# Env: GH_TOKEN, and GITHUB_REPOSITORY (default: 86inc/woocommerce-patched).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="$(jq -r '.upstream_repo' "$ROOT/patches.json")"
REPO="${GITHUB_REPOSITORY:-86inc/woocommerce-patched}"

tag="${1:-}"
force="${2:-false}"

latest="$(gh release list -R "$UPSTREAM" --exclude-pre-releases --exclude-drafts --limit 20 \
	--json tagName,isLatest --jq '.[] | select(.isLatest) | .tagName')"
if [ -z "$tag" ]; then
	tag="$latest"
fi

# Tags are version strings (11.1.1, 11.2.0-beta.2); anything else is rejected
# before it reaches a git ref or an API path.
if [ -z "$tag" ] || [ -n "$(tr -d '0-9A-Za-z.-' <<<"$tag")" ]; then
	echo "Invalid tag: '$tag'" >&2
	exit 1
fi
if ! gh api "repos/$UPSTREAM/git/ref/tags/$tag" --silent 2>/dev/null; then
	echo "Tag $tag does not exist in $UPSTREAM" >&2
	exit 1
fi

build="$tag+$("$ROOT/bin/patch-set-hash.sh")"

skip=false
highest=0
while read -r release_tag; do
	number="${release_tag#"$tag-build."}"
	if [ "$number" = "$release_tag" ] || [ -n "$(tr -d '0-9' <<<"$number")" ]; then
		continue
	fi
	if [ "$number" -gt "$highest" ]; then
		highest="$number"
	fi
	if gh release view "$release_tag" -R "$REPO" --json body --jq .body | grep -qF "Build: $build"; then
		skip=true
	fi
done < <(gh release list -R "$REPO" --limit 200 --json tagName --jq '.[].tagName')

if [ "$force" = "true" ]; then
	skip=false
fi

echo "tag=$tag"
echo "build=$build"
echo "release_tag=$tag-build.$((highest + 1))"
echo "is_latest=$([ "$tag" = "$latest" ] && echo true || echo false)"
echo "skip=$skip"
