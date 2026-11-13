# Intent: optional pickup location pre-selection

Upstream: no PR yet. Branch `add/pickup-location-preselect-filter`.

## Must achieve

- PHP filter `woocommerce_blocks_preselect_pickup_location` (bool, default true) is passed to the Checkout block as the `preselectPickupLocation` setting.
- When it is false and the server has no pickup location selected, the pickup options block starts with no location and does not call `selectShippingRate` on mount.
- While locations exist and none is selected, the block registers the hidden validation error `pickup-location` ("Please choose a pickup location."), shown under the list when the shopper tries to place the order. Choosing a location clears it, and so does unmounting the block (switching back to Ship).

## Must not change

- The default: the first location is selected, as before.
- A location the server already marks as selected is kept.

## Watch upstream

- `blocks/checkout/inner-blocks/checkout-pickup-options-block/block.tsx`: the initial `selectedOption` and the mount effect.
- `blocks/checkout/inner-blocks/checkout-shipping-method-block/`: what switching between Ship and Pickup selects.
- `src/Blocks/BlockTypes/Checkout.php`: `enqueue_data()`.

## Tests

- Jest: `checkout-pickup-options-block/test/block.tsx`.
- PHPUnit: `test_enqueue_data_exposes_preselect_pickup_location`.

## Known limitation

- Until a location is chosen, the session keeps its previous shipping rate, so the order summary shows that rate's cost (for example a flat rate) under "Pickup". The validation error stops the order being placed in that state.
