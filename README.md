# WooCommerce, patched by 86inc

Builds of WooCommerce stable releases with a small set of patches applied, published automatically as GitHub releases. This is **not** an official WooCommerce build.

The current patches make WooCommerce's blocks work with aggressive CDN caching, while their upstream pull requests are in review:

| Patch | Upstream PR |
| ----- | ----------- |
| Nonce timestamp key and trusted flag | [#66950](https://github.com/woocommerce/woocommerce/pull/66950) |
| Mini-Cart script module and `restUrl` guard | [#66951](https://github.com/woocommerce/woocommerce/pull/66951) |
| `woocommerce_embed_personalized_data` filter | [#64289](https://github.com/woocommerce/woocommerce/pull/64289) |

A patch is dropped once its upstream PR ships in a stable release.

## How it works

- Every 6 hours, [`build-release.yml`](.github/workflows/build-release.yml) checks for a new stable WooCommerce tag.
- [`bin/build.sh`](bin/build.sh) applies the patches listed in [`patches.json`](patches.json) onto the tag, then builds the zip with WooCommerce's own build script.
- [`bin/test.sh`](bin/test.sh) runs the Jest and PHPUnit suites the patches touch. [`bin/smoke-test.sh`](bin/smoke-test.sh) then loads the zip in wp-env, and checks that an anonymous visitor's cart doesn't leak into the page HTML.
- If everything passes, the zip is published as a release named `<tag>-build.<n>`. If anything fails, an issue is opened and nothing is published.
- When a patch conflicts or a test fails, [`repair.yml`](.github/workflows/repair.yml) asks Claude Code to refresh the patches, following each patch's `intent.md` ([task](ai/repair-task.md)). A separate job without AI re-checks the result from a clean checkout. If it passes, the result is opened as a PR to review and merge; nothing is merged or released automatically.

The plugin's slug and `Version:` match upstream exactly. A build is identified by its `86inc Patched Build` header and a prefix on the plugin description.

## Using it on a site

Copy [`mu-plugin/86inc-wc-patched.php`](mu-plugin/86inc-wc-patched.php) to `wp-content/mu-plugins/`. It then:

- Replaces WordPress.org's WooCommerce update with the newest patched build, once that build has been public for 48 hours. When no build exists yet for the version WordPress.org offers, the update is held, so vanilla WooCommerce never replaces a patched build.
- Verifies each download against the release's `woocommerce.zip.sha256` before installing it.
- Returns `false` from `woocommerce_embed_personalized_data` for logged-out visitors.
- Shows the installed build on the plugins screen and in Site Health.

Optional `wp-config.php` constants: `INC86_WC_PATCHED_SOAK_HOURS` (default `48`, e.g. `0` on a pilot site), `INC86_WC_NEUTRAL_ANONYMOUS_OUTPUT` (default `true`), and `INC86_WC_PATCHED_REPO`.

To withdraw a bad release from every site, mark it as a pre-release on GitHub.

## Running locally

Requires Node 24 (see the monorepo's `.nvmrc`), Docker, `jq`, and `composer`.

```sh
WC_SOURCE_REPO=../woocommerce bin/build.sh 11.1.1   # or omit WC_SOURCE_REPO to clone from GitHub
bin/test.sh 11.1.1
bin/smoke-test.sh 11.1.1
```

To trigger a release build manually:

```sh
gh workflow run build-release.yml -R 86inc/woocommerce-patched -f tag=11.1.1 [-f force=true] [-f dry_run=true]
```

## Verifying a release

Each release includes `woocommerce.zip.sha256` and `build-manifest.json`, which lists the build stamp, the zip's SHA-256, and how each patch applied.
