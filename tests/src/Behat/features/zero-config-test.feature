@api
Feature: Zero-configuration purging for Varnish

  Scenario: Purge node tags
    Given I visit "/"
    Then I should not see the text "Node title"
    And I am viewing an article with the title "Node title"
    And I purge nodes
    And I visit "/"
    Then I should see the text "Node title"

  Scenario: Purge specific URL
    Given I visit "/"
    Then I should not see the text "Node title"
    And I am viewing an article with the title "Node title"
    And I purge the home page
    And I visit "/"
    Then I should see the text "Node title"

  Scenario: Purge everything
    Given I visit "/"
    Then I should not see the text "Node title"
    And I am viewing an article with the title "Node title"
    And I purge everything
    And I visit "/"
    Then I should not see the text "Node title"

  Scenario: Page is cached
    Given I visit "/"
    Then I should not see the text "Node title"
    And I am viewing an article with the title "Node title"
    And I visit "/"
    Then I should not see the text "Node title"
