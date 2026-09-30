# Intent: nonce timestamp key + trusted flag

Upstream: [#66950](https://github.com/woocommerce/woocommerce/pull/66950)

## Must achieve

- `AssetsController` prints the Store API nonce timestamp under the key the middleware reads (`storeApiNonceTimestamp` in `wcBlocksMiddlewareConfig`), so the page-embedded nonce has a real timestamp.
- In `middleware/store-api-nonce.js`, `updateNonce( nonce, timestamp, trusted = false )`:
  - A nonce from a live response (`setNonce`, response headers) passes `trusted = true` and always replaces the stored nonce and timestamp, even when the stored timestamp is newer.
  - A page-embedded nonce (possibly from cached HTML) stays untrusted: it only wins when newer than the stored one.

## Must not change

- The `storeApiNonce` localStorage key and its shape.
- The `setNonce` signature on `apiFetch`, which other scripts call.
- Plugin version or database migrations.

## Watch upstream

- `client/blocks/assets/js/middleware/store-api-nonce.js`
- `src/Blocks/AssetsController.php`, the inline `wcBlocksMiddlewareConfig` output.
- Anything else calling `apiFetch.setNonce` or writing `storeApiNonce`.

## Tests

- Jest: `client/blocks/assets/js/middleware/test/store-api-nonce.js`.
