#!/usr/bin/env bash
#
# Smoke-test a built zip on wp-env as an anonymous visitor with a cart.
#
# Usage: bin/smoke-test.sh <tag> [--keep]
#
#   --keep  Leave the wp-env site running afterwards (default: stop it).
#
# With the personalization filter returning false, the cart and product page
# HTML must not contain the visitor's cart. Each check is repeated with the
# filter at its default as a control, which must show the cart; otherwise the
# check could never fail and proves nothing.
#
# Env:
#   WP_ENV_PORT     Port for the site (default: 8895).
#   WP_ENV_VERSION  @wordpress/env version (default: 11.9.0).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${WORK_DIR:-$ROOT/.work}"
PORT="${WP_ENV_PORT:-8895}"
WP_ENV_VERSION="${WP_ENV_VERSION:-11.9.0}"
PRODUCT_NAME="Smoke Test Tee"

TAG=""
KEEP=0
for arg in "$@"; do
	case "$arg" in
		--keep) KEEP=1 ;;
		-*) echo "Unknown option: $arg" >&2; exit 1 ;;
		*) TAG="$arg" ;;
	esac
done
if [ -z "$TAG" ]; then
	echo "Usage: bin/smoke-test.sh <tag> [--keep]" >&2
	exit 1
fi

ZIP="$ROOT/dist/$TAG/woocommerce.zip"
SITE="$WORK_ROOT/smoke-$TAG"
BASE_URL="http://localhost:$PORT"
COOKIES="$SITE/cookies.txt"
FAILURES=0

log() { printf '\n==> %s\n' "$*"; }
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

wp_env() { (cd "$SITE" && WP_ENV_PORT="$PORT" npx -y "@wordpress/env@$WP_ENV_VERSION" "$@"); }
wp() { wp_env run cli wp "$@" 2>/dev/null; }
# `wp option update` exits non-zero when the value is unchanged.
set_option() { wp eval "update_option( '$1', '$2' );" >/dev/null; }

setup_site() {
	if [ ! -f "$ZIP" ]; then
		echo "No build at ${ZIP#"$ROOT/"}. Run bin/build.sh $TAG first." >&2
		exit 1
	fi

	log "Preparing site in ${SITE#"$ROOT/"}"
	# Sync into the existing directory: replacing it would leave a running
	# container's bind mount pointing at the deleted one.
	mkdir -p "$SITE/woocommerce" "$SITE/unzipped"
	rm -rf "$SITE/unzipped/woocommerce"
	unzip -q "$ZIP" -d "$SITE/unzipped"
	rsync -a --delete "$SITE/unzipped/woocommerce/" "$SITE/woocommerce/"
	cp "$ROOT/tests/smoke/smoke-personalization.php" "$ROOT/tests/smoke/smoke-blocks.html" "$SITE/"
	cat > "$SITE/.wp-env.json" <<-JSON
		{
			"core": "https://wordpress.org/wordpress-latest.zip",
			"phpVersion": "8.1",
			"testsEnvironment": false,
			"plugins": [ "./woocommerce" ],
			"mappings": {
				"wp-content/mu-plugins/smoke-personalization.php": "./smoke-personalization.php",
				"wp-content/smoke-blocks.html": "./smoke-blocks.html"
			}
		}
	JSON

	log "Starting wp-env on port $PORT"
	local attempt
	for attempt in 1 2 3; do
		if wp_env start; then
			break
		fi
		if [ "$attempt" -eq 3 ]; then
			echo "wp-env failed to start after 3 attempts." >&2
			exit 1
		fi
		echo "wp-env start failed (attempt $attempt), retrying..."
		sleep 10
	done

	log "Configuring store"
	wp rewrite structure '/%postname%/' --hard >/dev/null
	set_option woocommerce_coming_soon no
	set_option smoke_embed_personalized_data no
	PRODUCT_ID="$(wp eval "
		\$existing = get_page_by_path( 'smoke-test-tee', OBJECT, 'product' );
		if ( \$existing ) { echo \$existing->ID; return; }
		\$product = new WC_Product_Simple();
		\$product->set_name( '$PRODUCT_NAME' );
		\$product->set_slug( 'smoke-test-tee' );
		\$product->set_regular_price( '19' );
		echo \$product->save();
	")"
	# A page with the Mini-Cart and Product Button blocks, which render cart data server-side.
	BLOCKS_URL="$(wp eval "
		\$existing = get_page_by_path( 'smoke-blocks' );
		\$id = \$existing ? \$existing->ID : wp_insert_post( array(
			'post_type'    => 'page',
			'post_status'  => 'publish',
			'post_name'    => 'smoke-blocks',
			'post_title'   => 'Smoke blocks',
			'post_content' => file_get_contents( WP_CONTENT_DIR . '/smoke-blocks.html' ),
		) );
		echo get_permalink( \$id );
	")"
	CART_URL="$(wp eval 'echo wc_get_cart_url();')"
}

check_plugin_identity() {
	log "Plugin identity"
	local name version description stamp
	name="$(wp plugin get woocommerce --field=title)"
	version="$(wp plugin get woocommerce --field=version)"
	description="$(wp plugin get woocommerce --field=description)"
	stamp="$(jq -r '.build' "$ROOT/dist/$TAG/build-manifest.json")"

	[ "$name" = "WooCommerce" ] && pass "title is '$name'" || fail "title is '$name', expected 'WooCommerce'"
	[ "$version" = "$TAG" ] && pass "version is $version" || fail "version is $version, expected $TAG"
	grep -qF "$stamp" <<<"$description" && pass "description names build $stamp" || fail "description '$description' lacks $stamp"
}

add_to_cart_as_visitor() {
	log "Adding product $PRODUCT_ID to an anonymous cart"
	rm -f "$COOKIES"
	local nonce
	nonce="$(curl -s -D - -o /dev/null -c "$COOKIES" -b "$COOKIES" "$BASE_URL/wp-json/wc/store/v1/cart" \
		| awk 'tolower($1) == "nonce:" { print $2 }' | tr -d '\r')"
	if [ -z "$nonce" ]; then
		fail "Store API returned no Nonce header"
		return
	fi

	local response count
	response="$(curl -s -c "$COOKIES" -b "$COOKIES" -H "Nonce: $nonce" -H 'Content-Type: application/json' \
		-d "{\"id\": $PRODUCT_ID, \"quantity\": 1}" "$BASE_URL/wp-json/wc/store/v1/cart/add-item")"
	count="$(jq -r '.items_count' <<<"$response")"
	CART_ITEM_KEY="$(jq -r '.items[0].key // empty' <<<"$response")"
	[ "$count" = "1" ] && pass "add-item returned items_count 1" || fail "add-item returned items_count '$count'"
}

# Usage: page_contains <url> <needle>
# Preloaded Store API data is URL-encoded in the page, so the HTML is decoded first.
page_contains() {
	curl -s -b "$COOKIES" "$1" \
		| python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' \
		| grep -qF "$2"
}

# The cart item key only exists in this visitor's cart data, so finding it in
# the HTML means the page was personalized.
check_pages() {
	local mode="$1"
	set_option smoke_embed_personalized_data "$([ "$mode" = control ] && echo yes || echo no)"

	local url needle
	for url in "$CART_URL" "$BLOCKS_URL"; do
		for needle in "$CART_ITEM_KEY" '"items_count":1'; do
			if [ "$mode" = neutral ]; then
				page_contains "$url" "$needle" && fail "neutral: $url contains $needle" || pass "neutral: $url has no $needle"
			else
				page_contains "$url" "$needle" && pass "control: $url contains $needle" || fail "control: $url lacks $needle, so the neutral check proves nothing"
			fi
		done
	done
}

check_store_api() {
	log "Store API still serves the real cart"
	local headers body
	headers="$(curl -s -D - -o "$SITE/cart.json" -b "$COOKIES" "$BASE_URL/wp-json/wc/store/v1/cart")"
	body="$(jq -r '.items_count' "$SITE/cart.json")"
	[ "$body" = "1" ] && pass "GET /cart returns items_count 1" || fail "GET /cart returns items_count '$body'"
	grep -qi '^nonce: ' <<<"$headers" && pass "GET /cart sends a Nonce header" || fail "GET /cart sends no Nonce header"
}

setup_site
check_plugin_identity
add_to_cart_as_visitor

log "Filter returns false (neutral output)"
check_pages neutral
log "Filter at its default (control)"
check_pages control
set_option smoke_embed_personalized_data no

check_store_api

if [ "$KEEP" -eq 0 ]; then
	wp_env stop >/dev/null 2>&1 || true
fi

echo
if [ "$FAILURES" -gt 0 ]; then
	echo "Smoke test failed: $FAILURES check(s)."
	exit 4
fi
echo "Smoke test passed."
