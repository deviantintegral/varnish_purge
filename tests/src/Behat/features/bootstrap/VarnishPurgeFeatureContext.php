<?php

use Behat\Behat\Context\SnippetAcceptingContext;
use Behat\Testwork\Hook\Scope\BeforeSuiteScope;
use Drupal\Core\Site\Settings;
use Drupal\DrupalExtension\Context\RawDrupalContext;

/**
 * Behat steps for testing the varnish_purger module.
 *
 * @codingStandardsIgnoreStart
 */
class VarnishPurgeFeatureContext extends RawDrupalContext implements SnippetAcceptingContext {

  /**
   * Setup for the test suite, enable some required modules and add content
   * title.
   *
   * @BeforeSuite
   */
  public static function prepare(BeforeSuiteScope $scope) {
    $data = Settings::getAll();

    // We need a concrete plugin class and one is included in the purge module.
    $data['extension_discovery_scan_tests'] = TRUE;

    // Technically this shouldn't include a port, but we need to work against
    // localhost and apache is on port 80 already.
    $data['reverse_proxy_addresses'] = [
      '127.0.0.1:8080',
    ];
    new Settings($data);

    /** @var \Drupal\Core\Extension\ModuleHandler $moduleHandler */
    $moduleHandler = \Drupal::service('module_handler');
    if (!$moduleHandler->moduleExists('varnish_purger')) {
      \Drupal::service('module_installer')->install(['varnish_purger', 'varnish_purge_tags', 'purge_processor_test']);
    }

    // Also uninstall the inline form errors module for easier testing.
    if ($moduleHandler->moduleExists('inline_form_errors')) {
      \Drupal::service('module_installer')->uninstall(['inline_form_errors']);
    }

    // Set a 1 year expiry as recommended by the purge module.
    \Drupal::service('config.factory')->getEditable('system.performance')
      ->set('cache', [
        'page' => [
          'max_age' => 365 * 24 * 60 * 60,
        ],
      ])
      ->save();

    // Add the zeroconfig purger as the only purger.
    \Drupal::service('config.factory')->getEditable('purge.plugins')
      ->set('purgers', [
        [
          'order_index' =>  1,
          'instance_id' => '340fedee82',
          'plugin_id' => 'varnish_zeroconfig_purger',
        ],
      ])
      ->save();
  }

  /**
   * @param \Behat\Testwork\Hook\Scope\AfterSuiteScope $scope
   * @AfterSuite
   */
  public static function tearDown(\Behat\Testwork\Hook\Scope\AfterSuiteScope $scope) {
    static::purgeTag('node_list');
  }

  /**
   * @When I purge nodes
   */
  public function iPurgeNodes() {
    $this->purgeTag('node_list');
  }

  /**
   * @When I purge the home page
   */
  public function iPurgeTheHomepage() {
    $p = \Drupal::service('purge.purgers');
    // This dummy processor is literally called "a".
    $a = \Drupal::service('purge.processors')->get('a');
    $invalidations = [
      \Drupal::service('purge.invalidation.factory')
        ->get('url', '/')
    ];

    // Varnish does have a queue, so if we get random failures we may need a
    // sleep here.
    $p->invalidate($a, $invalidations);
  }

  private static function purgeTag(string $tag) {
    $p = \Drupal::service('purge.purgers');
    // This dummy processor is literally called "a".
    $a = \Drupal::service('purge.processors')->get('a');
    $invalidations = [
      \Drupal::service('purge.invalidation.factory')
        ->get('tag', $tag)
    ];

    // Varnish does have a queue, so if we get random failures we may need a
    // sleep here.
    $p->invalidate($a, $invalidations);
  }

}
