# Intent: Mini-Cart cart snapshot

Upstream: no PR yet. Branch `fix/mini-cart-instant-count-from-storage`, stacked on `edge-cache-filter`.

## Must achieve

- After every live cart response in the iAPI cart store (the `refreshCartItems` GET and each batch `commit`), `saveCartSnapshot()` in `base/stores/woocommerce/cart-snapshot.ts` stores `items_count`, `items_weight`, `totals` and `saved_at` in localStorage under `wcBlocksCartSnapshot`. An empty cart removes the key.
- When the store loads with a server cart that has no items and `items_count` 0, `seedCartFromSnapshot()` copies those fields onto `state.cart` and the store sets `state.isCartSeeded`. `items` is never seeded.
- The Mini-Cart `totalItemsInCart` getter returns `cart.items_count` while `isCartSeeded` is true. The next live response clears the flag.
- A snapshot is ignored and removed when the `woocommerce_items_in_cart` cookie is missing, when it is older than 48 hours, or when it is malformed.

## Must not change

- The snapshot holds no line items, addresses or other personal data, and does not use the `storeApiCartData` / `storeApiCartHash` keys owned by the `wc/store/cart` persistence layer.
- `nonOptimisticProperties` and PHP output: the badge keeps its optimistic updates.
- Pages whose server cart has items render exactly as before.

## Watch upstream

- `client/blocks/assets/js/base/stores/woocommerce/cart.ts`: where `state.cart` is assigned from a server response, and the mutation queue's `commit`.
- `client/blocks/assets/js/blocks/mini-cart/frontend.ts`: `totalItemsInCart`.
- How WooCommerce sets or clears the `woocommerce_items_in_cart` cookie.

## Tests

- Jest: `base/stores/woocommerce/test/cart-snapshot.ts`, and the "cart snapshot for pages rendered without cart data" block in `base/stores/woocommerce/test/cart.ts`.
