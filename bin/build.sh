#!/usr/bin/env bash
#
# Build a patched WooCommerce zip from an upstream release tag.
#
# Usage: bin/build.sh <tag> [--apply-only] [--fresh]
#
#   --apply-only  Stop after applying patches (no install, build, or zip).
#   --fresh       Delete an existing work directory for this tag first.
#
# Each applied patch is committed in the work directory, so a conflicting patch
# can be resolved there and re-exported with `git diff HEAD`.
#
# Env:
#   WC_SOURCE_REPO  Local monorepo path or git URL (default: GitHub upstream).
#   WORK_DIR        Where tag checkouts live (default: ./.work).
#
# Exit codes: 0 success, 1 usage/setup error, 2 patch conflict, 3 build error.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches.json"
SOURCE_REPO="${WC_SOURCE_REPO:-https://github.com/$(jq -r '.upstream_repo' "$MANIFEST").git}"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"
BUILD_STAMP_HEADER="86inc Patched Build"

TAG=""
APPLY_ONLY=0
FRESH=0
for arg in "$@"; do
	case "$arg" in
		--apply-only) APPLY_ONLY=1 ;;
		--fresh) FRESH=1 ;;
		-*) echo "Unknown option: $arg" >&2; exit 1 ;;
		*) TAG="$arg" ;;
	esac
done

if [ -z "$TAG" ]; then
	echo "Usage: bin/build.sh <tag> [--apply-only] [--fresh]" >&2
	exit 1
fi

WORK="$WORK_ROOT/$TAG"
DIST="$ROOT/dist/$TAG"
REPORT="$WORK_ROOT/$TAG.report.json"

log() { printf '\n==> %s\n' "$*"; }

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$@"
	else
		shasum -a 256 "$@"
	fi
}

git_work() {
	git -C "$WORK" -c user.name="86inc build" -c user.email="build@86inc.invalid" "$@"
}

checkout_tag() {
	if [ -d "$WORK" ]; then
		if [ "$FRESH" -eq 1 ]; then
			rm -rf "$WORK"
		else
			echo "$WORK already exists. Re-run with --fresh to start over." >&2
			exit 1
		fi
	fi
	mkdir -p "$WORK_ROOT"

	log "Checking out $TAG from $SOURCE_REPO"
	if [ -d "$SOURCE_REPO/.git" ]; then
		# Local monorepo: share its object store instead of copying it.
		git clone --quiet --shared --no-checkout "$SOURCE_REPO" "$WORK"
		git_work checkout --quiet "tags/$TAG"
	else
		# Blobless clone: blobs a 3-way merge needs are fetched on demand.
		git clone --quiet --filter=blob:none --depth 1 --branch "$TAG" "$SOURCE_REPO" "$WORK"
	fi
	git_work switch --quiet -c "patched/$TAG"
}

# Prints one of: upstream, clean, 3way, conflict.
apply_patch() {
	local patch_file="$1"

	if git_work apply --reverse --check "$patch_file" 2>/dev/null; then
		echo "upstream"
	elif git_work apply --check "$patch_file" 2>/dev/null; then
		git_work apply --index "$patch_file"
		echo "clean"
	elif git_work apply --3way "$patch_file" >&2; then
		echo "3way"
	else
		echo "conflict"
	fi
}

# True when version $1 is lower than $2. Pre-release suffixes are ignored, so
# 11.2.0-beta.1 counts as 11.2.0.
version_lt() {
	local a="${1%%-*}" b="${2%%-*}"
	[ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$a" ]
}

apply_patches() {
	local results="[]"
	local id file min_version shipped_in status conflicted

	# Unit separator, not tab: `read` collapses runs of tabs, which would shift empty fields.
	while IFS=$'\x1f' read -r id file min_version shipped_in; do
		log "Applying $id"
		conflicted="[]"
		if [ -n "$min_version" ] && version_lt "$TAG" "$min_version"; then
			status="before-min-version"
		elif [ -n "$shipped_in" ] && ! version_lt "$TAG" "$shipped_in"; then
			status="shipped"
		else
			status="$(apply_patch "$ROOT/$file")"
			conflicted="$(git_work diff --name-only --diff-filter=U | jq -R . | jq -sc .)"
		fi
		echo "$id: $status"

		results="$(jq -c --arg id "$id" --arg status "$status" --argjson conflicted "$conflicted" \
			'. + [{id: $id, status: $status, conflicted_files: $conflicted}]' <<<"$results")"

		case "$status" in
			clean | 3way) git_work commit --quiet -m "Apply patch: $id" ;;
			conflict)
				jq -n --arg tag "$TAG" --argjson patches "$results" \
					'{tag: $tag, result: "conflict", patches: $patches}' > "$REPORT"
				echo "Conflict in $id. Resolve in $WORK, then re-export the patch." >&2
				git_work diff --name-only --diff-filter=U >&2
				exit 2
				;;
		esac
	done < <(jq -r '.patches[] | [.id, .file, .min_version // "", .shipped_in // ""] | join("\u001f")' "$MANIFEST")

	PATCH_RESULTS="$results"
}

# Marks woocommerce.php as a patched build: prefixes `Description:` with the
# manifest's `plugin_description_prefix` and adds the build identity header.
# `Plugin Name:`, the slug, and `Version:` stay untouched, since WooCommerce
# and WordPress compare them.
stamp_build() {
	local stamp="$1"
	local plugin_file="$WORK/plugins/woocommerce/woocommerce.php"
	local stamped="$plugin_file.stamped"
	local prefix
	prefix="$(jq -r '.plugin_description_prefix // ""' "$MANIFEST")"
	prefix="${prefix//\{build\}/$stamp}"

	awk -v stamp_line=" * $BUILD_STAMP_HEADER: $stamp" -v prefix="$prefix" '
		!described && index($0, " * Description: ") == 1 {
			print " * Description: " prefix substr($0, length(" * Description: ") + 1)
			described = 1
			next
		}
		{ print }
		!stamped && index($0, " * Version:") == 1 { print stamp_line; stamped = 1 }
	' "$plugin_file" > "$stamped"
	mv "$stamped" "$plugin_file"

	if ! grep -qF "$BUILD_STAMP_HEADER: $stamp" "$plugin_file" \
		|| ! grep -qF " * Description: $prefix" "$plugin_file"; then
		echo "Could not stamp $plugin_file (missing ' * Description:' or ' * Version:' header)." >&2
		exit 3
	fi
	git_work commit --quiet -am "Stamp build: $stamp"
}

require_node() {
	local required major
	required="$(jq -r '.engines.node' "$WORK/package.json")"
	major="$(node -p 'process.versions.node.split(".")[0]')"
	if [ "$major" != "$(tr -dc '0-9.' <<<"$required" | cut -d. -f1)" ]; then
		echo "Node $required required, found $(node -v). Try: nvm use $(tr -dc '0-9.' <<<"$required")" >&2
		exit 1
	fi
}

# Lifecycle scripts in the monorepo call `pnpm` directly, so put a corepack shim
# (resolving the version pinned by the tag's `packageManager`) first on PATH.
use_pnpm_shim() {
	mkdir -p "$WORK_ROOT/.bin"
	corepack enable --install-directory "$WORK_ROOT/.bin" pnpm
	export PATH="$WORK_ROOT/.bin:$PATH"
}

build_zip() {
	require_node
	use_pnpm_shim
	log "Installing dependencies (pnpm $(cd "$WORK" && pnpm --version))"
	(cd "$WORK" && pnpm install --frozen-lockfile --filter='@woocommerce/plugin-woocommerce...') || exit 3

	log "Building zip"
	(cd "$WORK/plugins/woocommerce" && SKIP_INSTALL=1 pnpm build:zip) || exit 3
}

write_outputs() {
	local stamp="$1"
	mkdir -p "$DIST"
	mv "$WORK/plugins/woocommerce/woocommerce.zip" "$DIST/woocommerce.zip"
	(cd "$DIST" && sha256 woocommerce.zip > woocommerce.zip.sha256)

	jq -n \
		--arg tag "$TAG" \
		--arg stamp "$stamp" \
		--arg sha256 "$(cut -d' ' -f1 "$DIST/woocommerce.zip.sha256")" \
		--arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson patches "$PATCH_RESULTS" \
		'{tag: $tag, build: $stamp, zip_sha256: $sha256, built_at: $built_at, patches: $patches}' \
		> "$DIST/build-manifest.json"

	log "Done: ${DIST#"$ROOT/"}"
	cat "$DIST/build-manifest.json"
}

checkout_tag
apply_patches

jq -n --arg tag "$TAG" --argjson patches "$PATCH_RESULTS" \
	'{tag: $tag, result: "applied", patches: $patches}' > "$REPORT"
if [ "$APPLY_ONLY" -eq 1 ]; then
	cat "$REPORT"
	exit 0
fi

STAMP="$TAG+$("$ROOT/bin/patch-set-hash.sh")"
stamp_build "$STAMP"
build_zip
write_outputs "$STAMP"
