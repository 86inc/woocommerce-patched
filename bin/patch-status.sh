#!/usr/bin/env bash
#
# Check the upstream PR behind each patch and print one status per patch as JSON.
#
# Usage: bin/patch-status.sh
#
# Statuses:
#   open     PR open, head matches our pinned_commit.
#   updated  PR open with commits after our pinned_commit.
#   merged   PR merged, not in a stable release yet.
#   shipped  In a stable release (`shipped_in`): its merge commit is in the tag's
#            history, or the tag already contains the patch's changes (cherry-picks).
#   closed   PR closed without merging.
#   local    No upstream PR.
# Patches already marked `shipped_in` in the manifest are reported as shipped
# without checking again.
#
# Env: GH_TOKEN.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
UPSTREAM="$(jq -r '.upstream_repo' "$MANIFEST")"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Stable upstream tags published after $1 (ISO date), oldest version first.
stable_tags_since() {
	gh release list -R "$UPSTREAM" --exclude-pre-releases --exclude-drafts --limit 40 \
		--json tagName,publishedAt \
		| jq -r --arg since "$1" '.[] | select(.publishedAt > $since) | .tagName' \
		| sort -V
}

tag_contains_commit() {
	local status
	status="$(gh api "repos/$UPSTREAM/compare/$1...$2?per_page=1" --jq .status 2>/dev/null || true)"
	[ "$status" = "ahead" ] || [ "$status" = "identical" ]
}

tag_contains_patch() {
	local tag="$1" patch_file="$2" dir="$SCRATCH/$1"
	if [ ! -d "$dir" ]; then
		git clone --quiet --filter=blob:none --depth 1 --branch "$tag" \
			"https://github.com/$UPSTREAM.git" "$dir" 2>/dev/null || return 1
	fi
	git -C "$dir" apply --reverse --check "$patch_file" 2>/dev/null
}

results="[]"
while IFS=$'\x1f' read -r id file pr pinned shipped_in; do
	entry="$(jq -n --arg id "$id" --arg pr "$pr" '{id: $id, pr: ($pr | if . == "" then null else tonumber end)}')"

	if [ -n "$shipped_in" ]; then
		entry="$(jq --arg v "$shipped_in" '. + {status: "shipped", shipped_in: $v, newly_shipped: false}' <<<"$entry")"
	elif [ -z "$pr" ]; then
		entry="$(jq '. + {status: "local"}' <<<"$entry")"
	else
		pull="$(gh api "repos/$UPSTREAM/pulls/$pr" \
			--jq '{state, merged, merged_at, merge_commit_sha, head: .head.sha, url: .html_url}')"
		entry="$(jq --argjson pull "$pull" '. + {url: $pull.url, head: $pull.head}' <<<"$entry")"

		if [ "$(jq -r .merged <<<"$pull")" = "true" ]; then
			merged_at="$(jq -r .merged_at <<<"$pull")"
			merge_sha="$(jq -r .merge_commit_sha <<<"$pull")"
			found=""
			tags="$(stable_tags_since "$merged_at")"
			while read -r tag; do
				[ -n "$tag" ] || continue
				if tag_contains_commit "$merge_sha" "$tag"; then
					found="$tag"
					break
				fi
			done <<<"$tags"
			latest="$(tail -1 <<<"$tags")"
			if [ -z "$found" ] && [ -n "$latest" ] && tag_contains_patch "$latest" "$ROOT/$file"; then
				found="$latest"
			fi
			if [ -n "$found" ]; then
				entry="$(jq --arg v "$found" '. + {status: "shipped", shipped_in: $v, newly_shipped: true}' <<<"$entry")"
			else
				entry="$(jq '. + {status: "merged"}' <<<"$entry")"
			fi
		elif [ "$(jq -r .state <<<"$pull")" = "closed" ]; then
			entry="$(jq '. + {status: "closed"}' <<<"$entry")"
		elif [ "$(jq -r .head <<<"$pull")" != "$pinned" ]; then
			entry="$(jq '. + {status: "updated"}' <<<"$entry")"
		else
			entry="$(jq '. + {status: "open"}' <<<"$entry")"
		fi
	fi

	results="$(jq --argjson e "$entry" '. + [$e]' <<<"$results")"
done < <(jq -r '.patches[] | [.id, .file, (.upstream_pr // "" | tostring), .pinned_commit // "", .shipped_in // ""] | join("\u001f")' "$MANIFEST")

jq . <<<"$results"
