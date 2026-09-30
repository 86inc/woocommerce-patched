<?php
/**
 * Plugin Name: 86inc WooCommerce patched builds
 * Description: Updates WooCommerce from 86inc/woocommerce-patched releases instead of WordPress.org, and serves cache-friendly block output to anonymous visitors.
 * Version: 1.0.0
 * Author: 86inc
 * Requires PHP: 7.4
 *
 * Settings (optional constants in wp-config.php):
 *   INC86_WC_PATCHED_REPO            GitHub repo to update from. Default '86inc/woocommerce-patched'.
 *   INC86_WC_PATCHED_SOAK_HOURS      Hours a release must be public before it is offered. Default 48.
 *   INC86_WC_NEUTRAL_ANONYMOUS_OUTPUT  Return false from woocommerce_embed_personalized_data for
 *                                    logged-out visitors. Default true.
 *
 * @package WooCommercePatched
 */

defined( 'ABSPATH' ) || exit;

/**
 * Update source and cache configuration for patched WooCommerce builds.
 */
final class Inc86_WC_Patched {

	const PLUGIN_FILE        = 'woocommerce/woocommerce.php';
	const BUILD_HEADER       = '86inc Patched Build';
	const RELEASES_TRANSIENT = 'inc86_wc_patched_releases';
	const CHECKSUMS_OPTION   = 'inc86_wc_patched_checksums';
	const RELEASE_SEPARATOR  = '-build.';

	/**
	 * Register hooks.
	 */
	public static function init() {
		add_filter( 'pre_set_site_transient_update_plugins', array( __CLASS__, 'filter_update_offer' ), 20 );
		add_filter( 'upgrader_pre_download', array( __CLASS__, 'verify_download' ), 10, 2 );
		add_filter( 'plugin_row_meta', array( __CLASS__, 'plugin_row_meta' ), 10, 2 );
		add_filter( 'debug_information', array( __CLASS__, 'debug_information' ) );

		if ( self::setting( 'INC86_WC_NEUTRAL_ANONYMOUS_OUTPUT', true ) ) {
			add_filter( 'woocommerce_embed_personalized_data', array( __CLASS__, 'embed_personalized_data' ) );
		}
	}

	/**
	 * Logged-out visitors get neutral markup that is safe for a shared cache.
	 *
	 * @param mixed $default_value Whether WooCommerce would embed personalized data.
	 * @return bool
	 */
	public static function embed_personalized_data( $default_value ) {
		return is_user_logged_in() ? (bool) $default_value : false;
	}

	/**
	 * Replace WordPress.org's WooCommerce update with the newest matching patched build.
	 *
	 * Offers the highest build newer than the installed one (or a rebuild of the installed
	 * version with a different patch set), capped at the version WordPress.org offers.
	 * When no build qualifies, the WordPress.org offer is removed so vanilla WooCommerce
	 * is never installed over a patched build.
	 *
	 * @param mixed $transient Value of the update_plugins site transient.
	 * @return mixed
	 */
	public static function filter_update_offer( $transient ) {
		if ( ! is_object( $transient ) ) {
			return $transient;
		}

		$installed = self::installed();
		if ( null === $installed ) {
			return $transient;
		}

		$offered         = $transient->response[ self::PLUGIN_FILE ] ?? null;
		$offered_version = is_object( $offered ) && isset( $offered->new_version ) ? (string) $offered->new_version : '';
		$candidate       = self::pick_release( $installed, $offered_version );
		$checksum        = $candidate ? self::fetch_checksum( $candidate ) : '';

		if ( $candidate && '' !== $checksum ) {
			$checksums                          = (array) get_option( self::CHECKSUMS_OPTION, array() );
			$checksums[ $candidate['zip_url'] ] = $checksum;
			update_option( self::CHECKSUMS_OPTION, array_slice( $checksums, -10, null, true ), false );

			$item = is_object( $offered ) ? clone $offered : (object) array(
				'id'     => 'w.org/plugins/woocommerce',
				'slug'   => 'woocommerce',
				'plugin' => self::PLUGIN_FILE,
				'url'    => 'https://github.com/' . self::repo(),
			);

			$item->new_version    = $candidate['version'];
			$item->package        = $candidate['zip_url'];
			$item->inc86_build    = $candidate['build'];
			$item->upgrade_notice = sprintf( '86inc patched build %s.', $candidate['build'] );

			$transient->response[ self::PLUGIN_FILE ] = $item;
			unset( $transient->no_update[ self::PLUGIN_FILE ] );
			return $transient;
		}

		if ( is_object( $offered ) ) {
			unset( $transient->response[ self::PLUGIN_FILE ] );
			$held                                      = clone $offered;
			$held->new_version                         = $installed['version'];
			$held->package                             = '';
			$transient->no_update[ self::PLUGIN_FILE ] = $held;
		}

		return $transient;
	}

	/**
	 * Only install our release zips when their SHA-256 matches the release's checksum file.
	 *
	 * @param mixed $reply   Short-circuit value from earlier filters.
	 * @param mixed $package Package URL being downloaded.
	 * @return mixed Path to the verified file, a WP_Error, or $reply for other packages.
	 */
	public static function verify_download( $reply, $package ) {
		if ( false !== $reply || ! is_string( $package ) || 0 !== strpos( $package, self::download_prefix() ) ) {
			return $reply;
		}

		$checksums = (array) get_option( self::CHECKSUMS_OPTION, array() );
		$expected  = isset( $checksums[ $package ] ) ? (string) $checksums[ $package ] : '';
		if ( '' === $expected ) {
			return new WP_Error( 'inc86_wc_patched_no_checksum', 'No checksum is known for this WooCommerce build; run the update check again.' );
		}

		if ( ! function_exists( 'download_url' ) ) {
			require_once ABSPATH . 'wp-admin/includes/file.php';
		}

		$file = download_url( $package, 300 );
		if ( is_wp_error( $file ) ) {
			return $file;
		}

		if ( ! hash_equals( $expected, (string) hash_file( 'sha256', $file ) ) ) {
			wp_delete_file( $file );
			return new WP_Error( 'inc86_wc_patched_checksum_mismatch', 'The downloaded WooCommerce build does not match its published checksum.' );
		}

		return $file;
	}

	/**
	 * Show which build is installed on the plugins screen.
	 *
	 * @param mixed $meta Row meta links.
	 * @param mixed $file Plugin file.
	 * @return mixed
	 */
	public static function plugin_row_meta( $meta, $file ) {
		if ( self::PLUGIN_FILE !== $file || ! is_array( $meta ) ) {
			return $meta;
		}

		$installed = self::installed();
		$meta[]    = $installed && '' !== $installed['build']
			? esc_html( sprintf( '86inc patched build %s', $installed['build'] ) )
			: esc_html( 'Not an 86inc patched build' );
		return $meta;
	}

	/**
	 * Add the build and update settings to Site Health > Info.
	 *
	 * @param mixed $info Site Health debug sections.
	 * @return mixed
	 */
	public static function debug_information( $info ) {
		if ( ! is_array( $info ) ) {
			return $info;
		}

		$installed                = self::installed();
		$info['inc86-wc-patched'] = array(
			'label'  => '86inc WooCommerce patched builds',
			'fields' => array(
				'build'      => array(
					'label' => 'Installed build',
					'value' => $installed && '' !== $installed['build'] ? $installed['build'] : 'Not a patched build',
				),
				'repo'       => array(
					'label' => 'Update source',
					'value' => self::repo(),
				),
				'soak_hours' => array(
					'label' => 'Soak period (hours)',
					'value' => self::soak_hours(),
				),
			),
		);
		return $info;
	}

	/**
	 * Choose the release to offer, or null.
	 *
	 * @param array  $installed       Installed version and build stamp.
	 * @param string $offered_version Version WordPress.org offers, or ''.
	 * @return array|null
	 */
	private static function pick_release( array $installed, string $offered_version ) {
		$best = null;
		foreach ( self::releases() as $release ) {
			if ( time() - $release['published'] < self::soak_hours() * HOUR_IN_SECONDS ) {
				continue;
			}
			if ( '' !== $offered_version && version_compare( $release['version'], $offered_version, '>' ) ) {
				continue;
			}

			$newer   = version_compare( $release['version'], $installed['version'], '>' );
			$rebuild = $release['version'] === $installed['version'] && $release['build'] !== $installed['build'];
			if ( ! $newer && ! $rebuild ) {
				continue;
			}

			if ( null === $best
				|| version_compare( $release['version'], $best['version'], '>' )
				|| ( $release['version'] === $best['version'] && $release['number'] > $best['number'] ) ) {
				$best = $release;
			}
		}
		return $best;
	}

	/**
	 * Published releases of the update repo, cached for 6 hours.
	 *
	 * Draft and pre-release entries are skipped, so marking a release as a
	 * pre-release on GitHub withdraws it from every site.
	 *
	 * @return array[] Each with version, number, build, zip_url, checksum_url, published.
	 */
	private static function releases(): array {
		// phpcs:ignore WordPress.Security.NonceVerification.Recommended -- Read-only flag from core's "Check again" link.
		$force  = ! empty( $_GET['force-check'] ) && current_user_can( 'update_plugins' );
		$cached = $force ? false : get_site_transient( self::RELEASES_TRANSIENT );
		if ( is_array( $cached ) ) {
			return $cached;
		}

		$response = wp_remote_get(
			'https://api.github.com/repos/' . self::repo() . '/releases?per_page=50',
			array(
				'timeout' => 15,
				'headers' => array( 'Accept' => 'application/vnd.github+json' ),
			)
		);

		$releases = array();
		$body     = json_decode( (string) wp_remote_retrieve_body( $response ), true );
		if ( ! is_wp_error( $response ) && 200 === wp_remote_retrieve_response_code( $response ) && is_array( $body ) ) {
			foreach ( $body as $entry ) {
				$release = is_array( $entry ) ? self::parse_release( $entry ) : null;
				if ( $release ) {
					$releases[] = $release;
				}
			}
		}

		// A failed lookup is cached briefly; with no releases known, WordPress.org updates stay held.
		set_site_transient( self::RELEASES_TRANSIENT, $releases, $releases ? 6 * HOUR_IN_SECONDS : HOUR_IN_SECONDS );
		return $releases;
	}

	/**
	 * Parse one GitHub release into the fields the updater needs, or null.
	 *
	 * @param array $entry Release object from the GitHub API.
	 * @return array|null
	 */
	private static function parse_release( array $entry ) {
		if ( ! empty( $entry['draft'] ) || ! empty( $entry['prerelease'] ) ) {
			return null;
		}

		$tag       = (string) ( $entry['tag_name'] ?? '' );
		$separator = strpos( $tag, self::RELEASE_SEPARATOR );
		if ( false === $separator ) {
			return null;
		}
		$version = substr( $tag, 0, $separator );
		$number  = substr( $tag, $separator + strlen( self::RELEASE_SEPARATOR ) );
		if ( '' === $version || ! ctype_digit( $number ) ) {
			return null;
		}

		$build = self::line_value( (string) ( $entry['body'] ?? '' ), 'Build: ' );
		if ( 0 !== strpos( $build, $version . '+' ) ) {
			return null;
		}

		$assets = array();
		foreach ( (array) ( $entry['assets'] ?? array() ) as $asset ) {
			$url = (string) ( $asset['browser_download_url'] ?? '' );
			if ( 0 === strpos( $url, self::download_prefix() ) ) {
				$assets[ (string) ( $asset['name'] ?? '' ) ] = $url;
			}
		}
		if ( empty( $assets['woocommerce.zip'] ) || empty( $assets['woocommerce.zip.sha256'] ) ) {
			return null;
		}

		return array(
			'version'      => $version,
			'number'       => (int) $number,
			'build'        => $build,
			'zip_url'      => $assets['woocommerce.zip'],
			'checksum_url' => $assets['woocommerce.zip.sha256'],
			'published'    => (int) strtotime( (string) ( $entry['published_at'] ?? '' ) ),
		);
	}

	/**
	 * Download a release's checksum file and return the SHA-256, or '' if invalid.
	 *
	 * @param array $release Parsed release.
	 * @return string
	 */
	private static function fetch_checksum( array $release ): string {
		$response = wp_remote_get( $release['checksum_url'], array( 'timeout' => 15 ) );
		if ( is_wp_error( $response ) || 200 !== wp_remote_retrieve_response_code( $response ) ) {
			return '';
		}

		$checksum = strtolower( substr( trim( (string) wp_remote_retrieve_body( $response ) ), 0, 64 ) );
		return ( 64 === strlen( $checksum ) && ctype_xdigit( $checksum ) ) ? $checksum : '';
	}

	/**
	 * Installed WooCommerce version and build stamp, or null when WooCommerce is absent.
	 *
	 * @return array|null
	 */
	private static function installed() {
		$path = WP_PLUGIN_DIR . '/' . self::PLUGIN_FILE;
		if ( ! is_readable( $path ) ) {
			return null;
		}

		$data = get_file_data(
			$path,
			array(
				'version' => 'Version',
				'build'   => self::BUILD_HEADER,
			)
		);
		return array(
			'version' => (string) $data['version'],
			'build'   => (string) $data['build'],
		);
	}

	/**
	 * Text after $prefix on the first line starting with it, or ''.
	 *
	 * @param string $text   Multi-line text.
	 * @param string $prefix Line prefix.
	 * @return string
	 */
	private static function line_value( string $text, string $prefix ): string {
		foreach ( explode( "\n", $text ) as $line ) {
			$line = trim( $line );
			if ( 0 === strpos( $line, $prefix ) ) {
				return trim( substr( $line, strlen( $prefix ) ) );
			}
		}
		return '';
	}

	/**
	 * Only release assets from this URL prefix are offered or verified.
	 *
	 * @return string
	 */
	private static function download_prefix(): string {
		return 'https://github.com/' . self::repo() . '/releases/download/';
	}

	/**
	 * GitHub repo to update from.
	 *
	 * @return string
	 */
	private static function repo(): string {
		return (string) self::setting( 'INC86_WC_PATCHED_REPO', '86inc/woocommerce-patched' );
	}

	/**
	 * Hours a release must be public before it is offered.
	 *
	 * @return int
	 */
	private static function soak_hours(): int {
		return max( 0, (int) self::setting( 'INC86_WC_PATCHED_SOAK_HOURS', 48 ) );
	}

	/**
	 * Value of an optional wp-config.php constant.
	 *
	 * @param string $name          Constant name.
	 * @param mixed  $default_value Value when the constant is not defined.
	 * @return mixed
	 */
	private static function setting( string $name, $default_value ) {
		return defined( $name ) ? constant( $name ) : $default_value;
	}
}

Inc86_WC_Patched::init();
