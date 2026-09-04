# frozen_string_literal: true

module Flightdeck
  # The typefaces the dashboard can be rendered in.
  #
  # Each slug is stamped on <html data-font="…">, and `assets-src/input.css`
  # has one block per slug that remaps --font-ui. Nothing here knows the font
  # stacks: CSS owns those, so a family can be respelled in one place.
  # `test/ui_fonts_test.rb` keeps this list, the CSS blocks and the vendored
  # woff2 files in step.
  #
  # The mono face (IBM Plex Mono) is not configurable: tables and payload
  # previews depend on its tabular figures.
  module UiFonts
    LABELS = {
      "public-sans" => "Public Sans",
      "barlow" => "Barlow",
      "general-sans" => "General Sans",
      "inter" => "Inter",
      "manrope" => "Manrope",
      "system" => "System"
    }.freeze

    DEFAULT = "public-sans"

    # "system" ships no woff2 — it is whatever the OS uses for its own UI.
    BUNDLED = (LABELS.keys - [ "system" ]).freeze

    class << self
      def slugs
        LABELS.keys
      end

      def label(slug)
        LABELS[slug.to_s]
      end

      def valid?(slug)
        LABELS.key?(slug.to_s)
      end

      # [slug, label] pairs in menu order: the default, then alphabetical.
      def options
        LABELS.map { |slug, label| [ slug, label ] }
      end
    end
  end
end
