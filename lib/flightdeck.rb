# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"

require "flightdeck/version"
require "flightdeck/ui_fonts"
require "flightdeck/configuration"
require "flightdeck/assets"

module Flightdeck
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Resolved at controller-definition time. Zeitwerk loads the engine's
    # controllers lazily, so host configuration set in an initializer wins.
    def base_controller_class
      name = config.base_controller_class
      name.presence ? name.to_s.constantize : ActionController::Base
    end
  end
end

require "flightdeck/engine"
