# Intent: edge-cache personalization filter

Upstream: [#64289](https://github.com/woocommerce/woocommerce/pull/64289)

## Must achieve

- `HydrationUtil::should_hydrate( $namespace )` decides whether server-rendered output embeds per-user data. The default is request-aware: true when the user is logged in or the cart is not empty. The filter `woocommerce_embed_personalized_data` receives the default and the block or store namespace.
- When it returns false, blocks emit neutral markup safe for a shared cache, and per-user data loads on the client:
  - Cart, Checkout, Mini-Cart (and its footer and title counter), and Product Button render empty-cart state and no item counts.
  - `BlocksSharedState` provides the empty cart schema instead of the real cart.
  - Checkout renders `CheckoutSkeleton` until the `getCheckoutData` resolver has loaded `GET /wc/store/v1/checkout?__experimental_calc_totals=true`, which returns `__experimentalCart`.
- The iAPI cart store mirrors fetched cart data into the `wc/store/cart` data store (`pushCartToReduxStore`, which sets `window.wcIapiCartHydrated`), and mirrors response nonces into apiFetch (`pushNonceToApiFetchMiddleware`).

## Must not change

- `WC_Cache_Helper::prevent_caching()` and the no-cache headers on cart, checkout, and account pages. Hosts strip those themselves via `wp_headers`.
- Output when the filter is not used: logged-in and non-empty-cart requests render exactly as vanilla WooCommerce.
- Plugin version or database migrations.

## Watch upstream

- Anything reading `WC()->cart` or cart counts in `src/Blocks/BlockTypes/`.
- New blocks with `supports.interactivity` that render per-user data server-side.
- `src/StoreApi/Routes/V1/Checkout.php`, the GET route and `__experimental_calc_totals`.
- `client/blocks/packages/public-api/block-data/checkout/` and `.../cart/resolvers.ts` (moved from `assets/js/data/` in [#66974](https://github.com/woocommerce/woocommerce/pull/66974)).
- `client/blocks/assets/js/base/stores/woocommerce/cart.ts`.

## Tests

- PHPUnit: `tests/php/src/Blocks/Utils/BlocksSharedStateTest.php`.
- Jest: `packages/public-api/block-data/checkout/test/resolvers.ts`, `.../checkout/test/reducer.ts`.
- Smoke test: an anonymous visitor with a non-empty cart, with the filter returning false, gets no cart JSON or item counts in the cart page or product page HTML.
