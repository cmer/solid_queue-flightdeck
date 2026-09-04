# frozen_string_literal: true

require "test_helper"

class Flightdeck::DashboardTest < ActionDispatch::IntegrationTest
  setup do
    ENV["FLIGHTDECK_USERNAME"] = "pilot"
    ENV["FLIGHTDECK_PASSWORD"] = "correct-horse-battery"
  end

  test "the root page renders the layout with the digested css and js" do
    get_authenticated "/flightdeck"

    assert_response :success
    assert_equal "text/html", response.media_type

    assert_includes response.body, %(<link rel="stylesheet" href="/flightdeck/assets/#{Flightdeck::Assets.digested_name("flightdeck.css")}">)
    assert_includes response.body, %(<script src="/flightdeck/assets/#{Flightdeck::Assets.digested_name("flightdeck.js")}" defer></script>)
  end

  test "the layout carries the Turbo root, CSRF meta and the toast target" do
    get_authenticated "/flightdeck"

    assert_includes response.body, %(<meta name="turbo-root" content="/flightdeck/">)
    assert_includes response.body, %(name="csrf-token")
    assert_includes response.body, %(id="fd-toasts")
    assert_includes response.body, %(data-controller="theme font")
  end

  test "the layout stamps the configured UI font, so the first paint is already right" do
    get_authenticated "/flightdeck"

    assert_includes response.body, %(<html lang="en" data-font="public-sans">)
  end

  test "the font picker offers every face, with the configured one selected" do
    with_ui_font("inter") do
      get_authenticated "/flightdeck"

      assert_includes response.body, %(<html lang="en" data-font="inter">)
      assert_includes response.body, %(<option value="inter" selected>Inter</option>)

      Flightdeck::UiFonts.slugs.each do |slug|
        assert_includes response.body, %(<option value="#{slug}")
      end
    end
  end


  test "the shell renders the brand and navigation" do
    get_authenticated "/flightdeck"

    assert_includes response.body, "FLIGHT<em>DECK</em>"
    assert_includes response.body, "Overview"
    assert_includes response.body, "fd-nav-link on"
  end

  test "the engine has its own session cookie regardless of the host" do
    get_authenticated "/flightdeck"

    assert response.headers["Set-Cookie"].to_s.include?("_flightdeck_session"),
           "expected the engine-local CookieStore to set _flightdeck_session, got: " \
           "#{response.headers["Set-Cookie"].inspect}"
  end

  test "flash and session are usable inside the engine even when the host is API-only" do
    get_authenticated "/flightdeck"

    assert_response :success
    assert_equal ENV["FLIGHTDECK_TEST_API_ONLY"].present?, Rails.application.config.api_only
  end

  private
    # Read at render time, so unlike base_controller_class this is safe to move
    # in-process.
    def with_ui_font(slug)
      original = Flightdeck.config.ui_font
      Flightdeck.config.ui_font = slug
      yield
    ensure
      Flightdeck.config.ui_font = original
    end

    def get_authenticated(path, **options)
      headers = (options.delete(:headers) || {}).merge(
        "HTTP_AUTHORIZATION" => basic_auth_header(ENV["FLIGHTDECK_USERNAME"], ENV["FLIGHTDECK_PASSWORD"])
      )
      get path, headers: headers, **options
    end
end
