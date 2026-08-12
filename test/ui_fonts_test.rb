# frozen_string_literal: true

require "test_helper"

# The UI font list is spread over three places that cannot see each other: the
# Ruby registry (menu + config validation), the `[data-font]` blocks in the
# stylesheet, and the woff2 files vendored under assets-src/fonts. A slug
# missing from any one of them fails quietly — the picker offers a face that
# never arrives, and the browser silently falls back to system-ui.
class Flightdeck::UiFontsTest < ActiveSupport::TestCase
  CSS = Pathname.new(File.expand_path("../assets-src/input.css", __dir__))
  FONTS = Pathname.new(File.expand_path("../assets-src/fonts/fonts.json", __dir__))

  setup do
    @css = CSS.read
    @vendored = JSON.parse(FONTS.read)
  end

  test "every offered font has a block that remaps --font-ui" do
    Flightdeck::UiFonts.slugs.each do |slug|
      assert_match(/\[data-font="#{Regexp.escape(slug)}"\] \{ --font-ui: /, @css,
                   "#{slug} has no [data-font] block in input.css")
    end
  end

  test "the stylesheet offers no font the registry does not" do
    stamped = @css.scan(/\[data-font="([a-z-]+)"\]/).flatten.uniq

    assert_equal Flightdeck::UiFonts.slugs.sort, stamped.sort
  end

  test "every bundled font names a family that is actually vendored" do
    families = @vendored.values.map { |meta| meta["family"] }.uniq

    Flightdeck::UiFonts::BUNDLED.each do |slug|
      block = @css[/\[data-font="#{Regexp.escape(slug)}"\] \{ --font-ui: ([^}]+)\}/, 1]
      family = block[/"([^"]+)"/, 1]

      assert family, "#{slug} does not name a family to load"
      assert_includes families, family, "#{family} is not vendored in assets-src/fonts"
    end
  end

  test "the system font ships no files and falls back to the OS stack" do
    block = @css[/\[data-font="system"\] \{ --font-ui: ([^}]+)\}/, 1]

    assert_equal "var(--font-system);", block.strip
  end

  test "the default is offered" do
    assert_includes Flightdeck::UiFonts.slugs, Flightdeck::UiFonts::DEFAULT
    assert_equal Flightdeck::UiFonts::DEFAULT, Flightdeck::UiFonts.options.first.first
  end

  test "every offered font has a label for the menu" do
    Flightdeck::UiFonts.slugs.each do |slug|
      assert_predicate Flightdeck::UiFonts.label(slug), :present?
    end
  end

  test "validity is a closed set" do
    assert Flightdeck::UiFonts.valid?("inter")
    assert Flightdeck::UiFonts.valid?(:inter)
    refute Flightdeck::UiFonts.valid?("comic-sans")
    refute Flightdeck::UiFonts.valid?(nil)
  end
end
