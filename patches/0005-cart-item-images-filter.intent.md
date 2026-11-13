# Intent: `cartItemImages` checkout filter

Upstream: no PR yet. Branch `add/cart-item-images-checkout-filter`.

## Must achieve

- A `cartItemImages` checkout filter (`registerCheckoutFilters`) chooses which images a cart line item (`context: 'cart'`) and an order summary item (`context: 'summary'`) show. It receives the first image as `[ images[0] ]`, the item's extensions, and `{ context, cartItem, cart }`.
- Values that are not an array of image objects are rejected by `cartItemImagesValidation`, and the default is used.
- With two or more images, `ProductImages` renders `ul.wc-block-components-product-images` with one `li.wc-block-components-product-images__item` per image, scrolling horizontally with CSS scroll-snap. Each image's fallback alt is "<name>, image N of M".

## Must not change

- Output without the filter: zero or one image renders the same `ProductImage` markup as before, inside the same product link (or none for hidden products).
- The Store API: which images are sent is still decided by `woocommerce_store_api_cart_item_images`.

## Watch upstream

- `base/components/cart-checkout/cart-line-items-table/cart-line-item-row.tsx` and `order-summary/order-summary-item.tsx`: the image cell markup.
- `base/components/cart-checkout/product-image/`: its props.
- The checkout filter registry (`applyCheckoutFilter`).

## Tests

- Jest: `base/components/cart-checkout/product-images/test/index.tsx`, `cart-line-items-table/test/cart-line-item-row.tsx`.
