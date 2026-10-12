# frozen_string_literal: true

require "test_helper"

# The engine brings its own cookie session only for hosts that have none. A host
# with a session of its own must keep it: Flightdeck reads and writes that one,
# and never copies it into a second cookie.
class Flightdeck::SessionTest < FlightdeckIntegrationTest
  test "an API-only host gets the engine's own session cookie" do
    skip "full host: covered by the host-session tests" unless api_only?

    get_fd "/flightdeck"

    assert_includes set_cookie_names, "_flightdeck_session"
  end

  test "a host session is used in place, never copied into a Flightdeck cookie" do
    skip "API-only host: there is no host session" if api_only?

    sign_into_host("user_id" => 42)
    get_fd "/flightdeck"

    assert_response :success
    assert_not_includes set_cookie_names, "_flightdeck_session"
    assert_nil cookies["_flightdeck_session"]
  end

  test "CSRF and flash work through the host session, which keeps its own keys" do
    skip "API-only host: there is no host session" if api_only?

    sign_into_host("user_id" => 42)
    job = create_failed_job
    post_fd "/flightdeck/jobs/#{job.id}/retry"

    assert_response :redirect
    assert_match(/retried/i, flash[:notice].to_s)
    assert_nil cookies["_flightdeck_session"]
    assert_equal 42, host_session["user_id"]
  end

  private
    def api_only?
      Rails.application.config.api_only
    end

    def host_session_key
      Rails.application.config.session_options.fetch(:key)
    end

    def sign_into_host(data)
      jar = ActionDispatch::Request.new(Rails.application.env_config.merge("HTTP_HOST" => "www.example.com")).cookie_jar
      jar.encrypted[host_session_key] = { value: data.merge("session_id" => SecureRandom.hex(16)) }
      cookies[host_session_key] = jar.instance_variable_get(:@set_cookies).fetch(host_session_key)[:value]
    end

    def host_session
      env = Rails.application.env_config.merge("HTTP_COOKIE" => "#{host_session_key}=#{Rack::Utils.escape(cookies[host_session_key])}")
      ActionDispatch::Request.new(env).cookie_jar.encrypted[host_session_key] || {}
    end

    def set_cookie_names
      Array(response.headers["Set-Cookie"]).flat_map { |header| header.split("\n") }.map { |line| line[/\A[^=]+/] }
    end
end
