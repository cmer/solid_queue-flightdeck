# frozen_string_literal: true

require "test_helper"

# The bundled Turbo injects its progress-bar <style> (and an async-import <script>
# shim) at runtime and stamps them with the nonce it reads from a
# <meta name="csp-nonce"> tag. Under a strict, nonce-based CSP the layout must emit
# that tag or those injected elements are nonce-less and get blocked.
class Flightdeck::CspNonceTest < ActionDispatch::IntegrationTest
  USERNAME = "pilot"
  PASSWORD = "correct-horse-battery"

  # Seed a nonce-based CSP into the dummy app for the duration of this test only.
  # env_config is memoized, so writing the keys the CSP machinery reads applies it
  # to each request here, and restoring them keeps it out of every other test.
  CSP_ENV_KEYS = %w[
    action_dispatch.content_security_policy
    action_dispatch.content_security_policy_nonce_generator
    action_dispatch.content_security_policy_nonce_directives
  ].freeze

  setup do
    ENV["FLIGHTDECK_USERNAME"] = USERNAME
    ENV["FLIGHTDECK_PASSWORD"] = PASSWORD

    env = Rails.application.env_config
    @previous_csp_env = CSP_ENV_KEYS.to_h { |key| [ key, env[key] ] }
    env["action_dispatch.content_security_policy"] =
      ActionDispatch::ContentSecurityPolicy.new do |policy|
        policy.default_src :self
        policy.style_src :self # deliberately no :unsafe_inline
      end
    env["action_dispatch.content_security_policy_nonce_generator"] = ->(_request) { SecureRandom.base64(16) }
    env["action_dispatch.content_security_policy_nonce_directives"] = %w[style-src script-src]
  end

  teardown do
    Rails.application.env_config.merge!(@previous_csp_env)
  end

  test "the layout emits a csp-nonce meta tag under a nonce-based CSP" do
    get_dashboard

    meta_nonce = response.body[/<meta name="csp-nonce" content="([^"]*)"/, 1]
    assert meta_nonce.present?, "expected a non-empty csp-nonce meta tag in the layout"

    # A full host (not an api_only one) also carries the CSP response header; when
    # it does, the meta must carry the very same nonce the header advertises.
    if (header = response.headers["Content-Security-Policy"])
      assert_equal header[/style-src[^;]*'nonce-([^']+)'/, 1], meta_nonce,
                   "expected the csp-nonce meta tag to match the style-src nonce"
    end
  end

  test "the layout emits no csp-nonce meta tag when the host has no CSP" do
    Rails.application.env_config.merge!(@previous_csp_env) # drop the CSP for this request

    get_dashboard

    assert_not_includes response.body, %(name="csp-nonce")
  end

  private
    def get_dashboard
      get "/flightdeck", headers: { "HTTP_AUTHORIZATION" => basic_auth_header(USERNAME, PASSWORD) }
      assert_response :success
    end
end
