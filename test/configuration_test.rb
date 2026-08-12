# frozen_string_literal: true

require "test_helper"

class Flightdeck::ConfigurationTest < ActiveSupport::TestCase
  setup do
    @config = Flightdeck::Configuration.new
  end

  test "ships the documented defaults" do
    assert_nil @config.base_controller_class
    assert_nil @config.http_basic
    assert_equal false, @config.skip_authentication
    assert_equal 5.seconds, @config.poll_interval
    assert_equal 30.seconds, @config.chart_poll_interval
    assert_equal 25, @config.per_page
    assert_equal 500_000, @config.count_cap
    assert_equal 1_000, @config.bulk_action_limit
    assert_equal 30.seconds, @config.chart_cache_ttl
    assert_equal "UTC", @config.display_timezone
    assert_equal 50, @config.backtrace_lines
    assert_equal "public-sans", @config.ui_font
  end

  test "ui_font accepts any offered face" do
    Flightdeck::UiFonts.slugs.each do |slug|
      @config.ui_font = slug.to_sym

      assert_equal slug, @config.ui_font
    end
  end

  # Silently falling back would leave the host wondering why its configured
  # face never showed up.
  test "ui_font rejects a face that is not offered" do
    error = assert_raises(ArgumentError) { @config.ui_font = "comic-sans" }

    assert_match "comic-sans", error.message
    assert_match "public-sans", error.message
    assert_equal "public-sans", @config.ui_font
  end

  test "Flightdeck.configure yields the singleton config" do
    original = Flightdeck.config.per_page
    Flightdeck.configure { |config| config.per_page = 99 }

    assert_equal 99, Flightdeck.config.per_page
  ensure
    Flightdeck.config.per_page = original
  end

  test "resolve_http_basic prefers explicit configuration" do
    @config.http_basic = { username: "a", password: "b" }
    ENV["FLIGHTDECK_USERNAME"] = "c"
    ENV["FLIGHTDECK_PASSWORD"] = "d"

    assert_equal({ username: "a", password: "b" }, @config.resolve_http_basic)
  end

  test "resolve_http_basic falls back to the environment" do
    ENV["FLIGHTDECK_USERNAME"] = "c"
    ENV["FLIGHTDECK_PASSWORD"] = "d"

    assert_equal({ username: "c", password: "d" }, @config.resolve_http_basic)
  end

  test "resolve_http_basic ignores half-configured sources" do
    ENV["FLIGHTDECK_USERNAME"] = "c"

    assert_nil @config.resolve_http_basic

    @config.http_basic = { username: "a" }
    assert_nil @config.resolve_http_basic

    @config.http_basic = { username: "", password: "" }
    assert_nil @config.resolve_http_basic
  end

  test "resolve_http_basic accepts a callable so secrets can rotate" do
    calls = 0
    @config.http_basic = -> { calls += 1; { username: "a", password: "b#{calls}" } }

    assert_equal({ username: "a", password: "b1" }, @config.resolve_http_basic)
    assert_equal({ username: "a", password: "b2" }, @config.resolve_http_basic)
  end

  test "resolve_http_basic reads Rails credentials last" do
    assert_nil @config.resolve_http_basic

    Rails.application.credentials.stub(:flightdeck, { username: "cred", password: "secret" }) do
      assert_equal({ username: "cred", password: "secret" }, @config.resolve_http_basic)
    end
  end

  test "base_controller_class defaults to ActionController::Base and constantizes when set" do
    # Load the controller while nothing is configured, so this test cannot
    # leave a half-defined constant behind for the rest of the suite.
    controller = Flightdeck::ApplicationController
    assert_equal ActionController::Base, Flightdeck.base_controller_class
    refute_predicate controller, :host_authenticated?

    Flightdeck.config.base_controller_class = "ActionController::Base"
    assert_equal ActionController::Base, Flightdeck.base_controller_class
    assert_predicate controller, :host_authenticated?,
                     "a configured base controller must suppress Flightdeck's own challenge"
  end
end
