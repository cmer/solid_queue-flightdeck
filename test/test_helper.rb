# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

require "rails/test_help"
require "minitest/autorun"
require_relative "support/solid_queue_scenario"

ActiveRecord::Schema.verbose = false
load Rails.root.join("db", "schema.rb")

# Schema is loaded after boot, so cached column lists (and Solid Queue's
# Batch.migrated? memo) would otherwise describe the previous process's tables.
SolidQueue::Job.reset_column_information
if defined?(SolidQueue::Batch)
  SolidQueue::Batch.reset_column_information
  SolidQueue::Batch.remove_instance_variable(:@migrated) if SolidQueue::Batch.instance_variable_defined?(:@migrated)
end
SolidQueue::BatchExecution.reset_column_information if defined?(SolidQueue::BatchExecution)

module Flightdeck
  module TestHelpers
    BASIC_ENV_KEYS = %w[FLIGHTDECK_USERNAME FLIGHTDECK_PASSWORD].freeze

    # before_setup / after_teardown rather than setup / teardown, so that a
    # test case's own `setup do` block runs after the reset and can configure
    # credentials for itself.
    def before_setup
      super
      @__flightdeck_env = BASIC_ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
      @__flightdeck_http_basic = Flightdeck.config.http_basic
      @__flightdeck_base_controller = Flightdeck.config.base_controller_class
      @__flightdeck_skip_authentication = Flightdeck.config.skip_authentication

      BASIC_ENV_KEYS.each { |key| ENV.delete(key) }
      Flightdeck.config.http_basic = nil
      Flightdeck.config.base_controller_class = nil
      Flightdeck.config.skip_authentication = false
    end

    def after_teardown
      @__flightdeck_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Flightdeck.config.http_basic = @__flightdeck_http_basic
      Flightdeck.config.base_controller_class = @__flightdeck_base_controller
      Flightdeck.config.skip_authentication = @__flightdeck_skip_authentication
      super
    end

    def with_env_basic_auth(username: "pilot", password: "correct-horse-battery")
      ENV["FLIGHTDECK_USERNAME"] = username
      ENV["FLIGHTDECK_PASSWORD"] = password
      yield
    ensure
      ENV.delete("FLIGHTDECK_USERNAME")
      ENV.delete("FLIGHTDECK_PASSWORD")
    end

    def basic_auth_header(username, password)
      ActionController::HttpAuthentication::Basic.encode_credentials(username, password)
    end

    def with_batches_unavailable
      original = Flightdeck::BatchesQuery.method(:available?)
      Flightdeck::BatchesQuery.define_singleton_method(:available?) { false }
      yield
    ensure
      Flightdeck::BatchesQuery.define_singleton_method(:available?, original)
    end

    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA"
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end
end

class ActiveSupport::TestCase
  include Flightdeck::TestHelpers
  include SolidQueueScenario

  def before_setup
    super
    clear_solid_queue!
    # Counts and series are cached for a few seconds. Without this, one test's
    # numbers would still be warm when the next one runs.
    Rails.cache.clear
  end
end

# Integration tests that are about Flightdeck's behaviour rather than its
# authentication: credentials are configured, and requests carry them.
#
# Forgery protection stays ON (see config/environments/test.rb), so POSTs go
# through a real CSRF token read from a rendered page — which is also what makes
# the "posting without a token is rejected" test meaningful.
class FlightdeckIntegrationTest < ActionDispatch::IntegrationTest
  USERNAME = "pilot"
  PASSWORD = "correct-horse-battery"

  def before_setup
    super
    ENV["FLIGHTDECK_USERNAME"] = USERNAME
    ENV["FLIGHTDECK_PASSWORD"] = PASSWORD
  end

  def auth_headers(extra = {})
    extra.merge("HTTP_AUTHORIZATION" => basic_auth_header(USERNAME, PASSWORD))
  end

  def get_fd(path, headers: {}, **options)
    get path, headers: auth_headers(headers), **options
  end

  def post_fd(path, headers: {}, csrf: true, **options)
    headers = auth_headers(headers)
    headers["X-CSRF-Token"] = csrf_token if csrf
    post path, headers: headers, **options
  end

  def csrf_token
    @csrf_token ||= begin
      get_fd "/flightdeck/jobs"
      response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
    end
  end

  def turbo_stream_headers(extra = {})
    extra.merge("Accept" => "text/vnd.turbo-stream.html, text/html")
  end

  def job_ids_in_response
    response.body.scan(/id="fd-job-(\d+)"/).flatten.map(&:to_i)
  end
end
