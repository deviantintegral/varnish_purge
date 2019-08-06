@api
Feature: Zero-configuration purging for Varnish

  Scenario: Purge node tags
    Given I visit "/"
    Then I should not see the text "First version"
    And I am viewing an article with the title "First version"
    And I purge nodes
    And I visit "/"
    Then I should see the text "First version"
