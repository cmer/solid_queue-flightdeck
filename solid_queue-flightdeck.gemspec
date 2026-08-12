# frozen_string_literal: true

require_relative "lib/flightdeck/version"

Gem::Specification.new do |spec|
  spec.name = "solid_queue-flightdeck"
  spec.version = Flightdeck::VERSION
  spec.authors = [ "Carl Mercier" ]
  spec.email = [ "carl@carlmercier.com" ]

  spec.summary = "A beautiful, featureful dashboard for Solid Queue."
  spec.description = "Flightdeck is a mountable Rails engine that gives Solid Queue a fast, " \
                     "polished dashboard: jobs, failures, queues, processes, recurring tasks " \
                     "and live charts. Works in API-only hosts and ships its own precompiled assets."
  spec.homepage = "https://github.com/cmer/solid_queue-flightdeck"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "app/**/*",
    "config/**/*",
    "lib/**/*",
    "README.md",
    "MIT-LICENSE",
    "FONT-LICENSES.md"
  ]

  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "solid_queue", ">= 1.0"
end
