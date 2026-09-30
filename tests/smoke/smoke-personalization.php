<?php
/**
 * Plugin Name: 86inc smoke test: personalization toggle
 * Description: Returns false from woocommerce_embed_personalized_data unless the smoke_embed_personalized_data option is "yes".
 *
 * @package WooCommercePatched
 */

defined( 'ABSPATH' ) || exit;

add_filter(
	'woocommerce_embed_personalized_data',
	function ( $default_value ) {
		return 'yes' === get_option( 'smoke_embed_personalized_data', 'no' ) ? $default_value : false;
	}
);
