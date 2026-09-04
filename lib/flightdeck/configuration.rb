# frozen_string_literal: true

module Flightdeck
  class Configuration
    attr_accessor :base_controller_class,
                  :http_basic,
                  :skip_authentication,
                  :poll_interval,
                  :chart_poll_interval,
                  :per_page,
                  :count_cap,
                  :bulk_action_limit,
                  :chart_cache_ttl,
                  :display_timezone,
                  :backtrace_lines

    attr_reader :ui_font

    def initialize
      @base_controller_class = nil
      @http_basic = nil
      @skip_authentication = false
      @poll_interval = 5.seconds
      @chart_poll_interval = 30.seconds
      @per_page = 25
      @count_cap = 500_000
      @bulk_action_limit = 1_000
      @chart_cache_ttl = 30.seconds
      @display_timezone = "UTC"
      @backtrace_lines = 50
      @ui_font = UiFonts::DEFAULT
    end

    # The house default every user starts on; each user can pick another in the
    # UI. Validated on assignment so a typo surfaces in the host's initializer
    # rather than as a silent fallback in the browser.
    def ui_font=(value)
      slug = value.to_s
      unless UiFonts.valid?(slug)
        raise ArgumentError,
              "unknown Flightdeck ui_font #{value.inspect} — expected one of: #{UiFonts.slugs.join(", ")}"
      end

      @ui_font = slug
    end

    # Resolved fresh on every call so that credentials rotated in the
    # environment (or in Rails credentials) take effect without a restart,
    # and so that nothing touches Rails.application.credentials at boot.
    #
    # Returns a { username:, password: } hash, or nil when unconfigured.
    def resolve_http_basic
      from_explicit || from_env || from_credentials
    end

    private
      def from_explicit
        normalize(http_basic)
      end

      def from_env
        normalize(username: ENV["FLIGHTDECK_USERNAME"], password: ENV["FLIGHTDECK_PASSWORD"])
      end

      def from_credentials
        return nil unless defined?(Rails) && Rails.application

        normalize(Rails.application.credentials.flightdeck)
      rescue StandardError
        nil
      end

      def normalize(source)
        return nil if source.nil?

        # Only genuine callables are invoked. `respond_to?(:call)` is not a safe
        # test here: Rails credentials hand back an ActiveSupport::OrderedOptions,
        # whose method_missing answers true for every name and returns nil for
        # `call` — which used to swallow credential-configured auth entirely.
        source = source.call if source.is_a?(Proc) || source.is_a?(Method)
        return nil if source.nil?

        username = fetch(source, :username)
        password = fetch(source, :password)
        return nil if username.nil? || password.nil?

        username = username.to_s
        password = password.to_s
        return nil if username.empty? || password.empty?

        { username: username, password: password }
      end

      def fetch(source, key)
        if source.respond_to?(:[])
          source[key] || source[key.to_s]
        elsif source.respond_to?(key)
          source.public_send(key)
        end
      end
  end
end
