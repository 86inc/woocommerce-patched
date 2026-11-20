# Intent: multiple images per Mini-Cart line item

Upstream: no PR yet. Branch `add/mini-cart-item-images`.

## Must achieve

- The Mini-Cart (Interactivity API) applies the `cartItemImages` checkout filter, with `context: 'cart'`, when `wc.blocksCheckout` is loaded. The default is `[ images[0] ]`, and a value that is not an array of image objects is ignored.
- With two or more images, the line item shows `ul.wc-block-components-product-images` (inside the product link, or unlinked for products hidden from the catalog), one `li.wc-block-components-product-images__item` per image, scrolling horizontally with CSS scroll-snap. Each image's alt is its own alt, or the translated "<name>, image N of M".
- With one image, a filter that returns a different single image is shown in the existing single `<img>`.

## Must not change

- Zero or one image: the existing single `<img>` elements render and behave as before. The two image lists are present but hidden, and their `hidden` bindings are negated getters so server-rendered rows hide them too.
- The Store API: which images are sent is still decided by `woocommerce_store_api_cart_item_images`.

## Watch upstream

- `MiniCartProductsTableBlock.php`: the image cell markup and the config labels.
- `mini-cart/frontend.ts`: `itemThumbnail`, `isProductHiddenFromCatalog`, `hideImage` and the `woocommerce/mini-cart-products-table-block` store.

## Tests

- Jest: `mini-cart/utils/test/item-images.ts`.
- PHPUnit: `MiniCartProductsTableBlockTest`.
