# frozen_string_literal: true

require "action_dispatch"

module Flightdeck
  # Gives the engine a cookie session only when the host has none.
  #
  # An API-only host carries no cookies or session, so Flightdeck brings its own
  # (`_flightdeck_session`) for CSRF and flash. A host that already has a session
  # is passed straight through: stacking a second session store on top of it
  # would make Rails seed the new session with every key of the host's, then
  # write that copy out under Flightdeck's cookie — and the host's own filters
  # (base_controller_class) would read the copy instead of the original.
  class SessionFallback
    def initialize(app, **session_options)
      @app = app
      @fallback = ActionDispatch::Cookies.new(
        ActionDispatch::Session::CookieStore.new(app, **session_options)
      )
    end

    def call(env)
      host_session?(env) ? @app.call(env) : @fallback.call(env)
    end

    private
      def host_session?(env)
        session = env[Rack::RACK_SESSION]
        return false if session.nil?

        !session.respond_to?(:enabled?) || session.enabled?
      end
  end
end
