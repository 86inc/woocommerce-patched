# Intent: Mini-Cart script module + restUrl guard

Upstream: [#66951](https://github.com/woocommerce/woocommerce/pull/66951)

## Must achieve

- The `woocommerce/mini-cart` script module is only enqueued from `MiniCart::render()`, after its early return for the cart and checkout pages. It must not load on those pages, where the iAPI cart store has no `restUrl` and would loop refreshing the cart.
- `mini-cart/block.json` does not declare `viewScriptModule`, since a declared module is enqueued on every page the block appears on, including cart and checkout.
- In the iAPI cart store (`base/stores/woocommerce/cart.ts`), `refreshCartItems` returns early when `state.restUrl` is missing, and resolves the pending nonce promise so queued mutations fail visibly instead of hanging.

## Must not change

- The Mini-Cart's behavior on pages other than cart and checkout.
- The `woocommerce/mini-cart` module ID or its dependencies.
- Plugin version or database migrations.

## Watch upstream

- `src/Blocks/BlockTypes/MiniCart.php`, `render()` and the enqueue logic.
- `client/blocks/assets/js/blocks/mini-cart/block.json`.
- `client/blocks/assets/js/base/stores/woocommerce/cart.ts`, `refreshCartItems` and the nonce-ready promise.
- New blocks that import the `woocommerce` iAPI store without loading the shared cart state.

## Tests

- Jest: `client/blocks/assets/js/base/stores/woocommerce/test/cart.ts`.
- PHPUnit: `tests/php/src/Blocks/BlockTypes/MiniCart.php`.
