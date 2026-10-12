# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "solid_queue"
require "flightdeck/session_fallback"

module Flightdeck
  class Engine < ::Rails::Engine
    isolate_namespace Flightdeck

    # Engine-local middleware: wraps only requests routed into the mount, so
    # Flightdeck has cookies, a session and flash even when the host app is
    # `config.api_only = true` and carries none of them. A host that has its
    # own session keeps it: SessionFallback steps aside rather than copying it.
    middleware.use Flightdeck::SessionFallback,
                   key: "_flightdeck_session",
                   same_site: :lax,
                   httponly: true
    middleware.use ActionDispatch::Flash

    config.flightdeck = Flightdeck.config

    # Flightdeck speaks Turbo Streams but does not depend on turbo-rails: the
    # engine ships its own Turbo build. Registering the type is all the server
    # side actually needs, and the host may well have registered it already.
    initializer "flightdeck.mime_types" do
      Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]
    end
  end
end
