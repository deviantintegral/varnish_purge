<?php

namespace Drupal\Tests\varnish_purger\Functional;

use Drupal\Tests\BrowserTestBase;
use Drupal\Tests\node\Traits\NodeCreationTrait;

/**
 * @group varnish_purger
 */
class ZeroConfigPurgerTest extends BrowserTestBase {
  use NodeCreationTrait;

  protected $profile = 'standard';

  protected static $modules = [
    'filter',
    'node',
    'purge_processor_test',
    'varnish_purger',
  ];

  public function testProxy() {
    // sudo varnishd -F -a :8080 -T localhost:6082 -f $(pwd)/zeroconfig.vcl

    $node = $this->drupalCreateNode([
      'title' => $this->randomMachineName(),
    ]);
    $node->save();

    $response = $this->drupalGet('/node/1');
    $this->assertHeader('Cache-Control', 'max-age=31536000, public');

    $response = $this->drupalGet('http://localhost:8080/node/1');
    $this->assertContains($node->getTitle(), $response);

    $node->setTitle($this->randomMachineName());
    $node->save();

    $response = $this->drupalGet('http://localhost:8080/node/1');
    $this->assertContains($node->getTitle(), $response);
  }

}
