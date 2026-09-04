# frozen_string_literal: true

require "json"
require "pathname"

module Flightdeck
  # In-memory view of the precompiled asset manifest committed under
  # app/assets/flightdeck/. Loaded lazily and memoized: the gem must boot
  # cleanly in a checkout where `rake assets:build` has not run yet.
  module Assets
    CONTENT_TYPES = {
      ".css" => "text/css; charset=utf-8",
      ".js" => "text/javascript; charset=utf-8",
      ".woff2" => "font/woff2"
    }.freeze

    LOGICAL_NAMES = %w[flightdeck.css flightdeck.js].freeze

    class << self
      def root
        @root ||= Pathname.new(File.expand_path("../../app/assets/flightdeck", __dir__))
      end

      def manifest
        return @manifest if defined?(@manifest) && @manifest

        @manifest = load_manifest
      end

      # Reverse index: digested filename => entry. The only lookup the
      # controller performs, so a request can never name a file we did not
      # build.
      def by_digested_name
        @by_digested_name ||= manifest.each_with_object({}) do |(logical, entry), index|
          index[entry["file"]] = entry.merge("logical" => logical)
        end.freeze
      end

      def digested_name(logical)
        entry = manifest[logical.to_s]
        entry && entry["file"]
      end

      def find(digested_name)
        by_digested_name[digested_name.to_s]
      end

      def read(digested_name)
        entry = find(digested_name)
        return nil unless entry

        path = root.join(entry["file"])
        return nil unless path.file?

        path.binread
      end

      def content_type_for(file)
        CONTENT_TYPES.fetch(File.extname(file), "application/octet-stream")
      end

      private
        def load_manifest
          path = root.join("manifest.json")
          return {} unless path.file?

          JSON.parse(path.read).freeze
        rescue JSON::ParserError
          {}
        end
    end
  end
end
