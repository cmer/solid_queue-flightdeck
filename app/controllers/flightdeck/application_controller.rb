# frozen_string_literal: true

require "active_support/security_utils"

module Flightdeck
  class ApplicationController < Flightdeck.base_controller_class
    UNCONFIGURED_MESSAGE = <<~TEXT
      Flightdeck is not configured for authentication, so it is refusing to
      serve the dashboard.

      Pick one of the following, then restart your app.

      1. HTTP Basic via environment variables:

           FLIGHTDECK_USERNAME=admin FLIGHTDECK_PASSWORD=a-long-secret

      2. HTTP Basic via Rails credentials (bin/rails credentials:edit):

           flightdeck:
             username: admin
             password: a-long-secret

      3. HTTP Basic in an initializer (config/initializers/flightdeck.rb):

           Flightdeck.configure do |config|
             config.http_basic = { username: "admin", password: "a-long-secret" }
           end

      4. Reuse your application's own authentication by giving Flightdeck a
         base controller to inherit from:

           Flightdeck.configure do |config|
             config.base_controller_class = "Admin::BaseController"
           end

      5. If something upstream (a routing constraint, VPN, or reverse proxy)
         already guards this mount and you accept the risk, turn Flightdeck's
         gate off entirely:

           Flightdeck.configure do |config|
             config.skip_authentication = true
           end

      Flightdeck never serves unauthenticated requests, in any environment,
      unless it is explicitly told to with skip_authentication.
    TEXT

    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    layout "flightdeck/application"

    # Declared explicitly rather than relying on isolate_namespace: when the host
    # supplies its own base controller, that controller's helper set is the one
    # Rails wires up, and Flightdeck's own helpers would otherwise be missing.
    helper Flightdeck::Engine.helpers

    # Prepended so that an unauthenticated request is turned away before any
    # other filter — including CSRF verification — gets a chance to answer it
    # with a different status.
    prepend_before_action :authenticate_flightdeck!

    helper_method :list_filters

    class << self
      # True when the host handed us its own base controller: that controller's
      # own filters are already in our callback chain, so Flightdeck must not
      # layer a second, conflicting challenge on top of it.
      def host_authenticated?
        Flightdeck.config.base_controller_class.present?
      end
    end

    private
      # The filter set that identifies a list. Carried through pagination links,
      # frame refreshes and "apply to all matching" so that every one of them is
      # looking at exactly the same set of rows.
      def list_filters
        @list_filters ||= {
          class_name: params[:class_name].presence,
          queue_name: params[:queue_name].presence,
          q: params[:q].presence
        }.compact
      end

      # Read per request, like the rest of the auth config, so nothing is
      # resolved at boot. `skip_authentication` is the explicit opt-out for
      # deployments that gate the mount upstream — a routing constraint, a VPN,
      # a reverse proxy — and it wins over every other setting here.
      def authenticate_flightdeck!
        return if Flightdeck.config.skip_authentication
        return if self.class.host_authenticated?

        credentials = Flightdeck.config.resolve_http_basic
        return render_unconfigured if credentials.nil?

        authenticate_or_request_with_http_basic("Flightdeck") do |username, password|
          secure_equal?(username, credentials[:username]) &
            secure_equal?(password, credentials[:password])
        end
      end

      def secure_equal?(given, expected)
        ActiveSupport::SecurityUtils.secure_compare(given.to_s, expected.to_s)
      end

      def render_unconfigured
        render plain: UNCONFIGURED_MESSAGE, status: :unauthorized, layout: false
      end
  end
end
