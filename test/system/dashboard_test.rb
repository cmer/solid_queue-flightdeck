# frozen_string_literal: true

require "application_system_test_case"

class Flightdeck::DashboardSystemTest < ApplicationSystemTestCase
  # Found by its accessible label rather than its text: the toggle is icon-only.
  def theme_button
    find("button[aria-label^='Switch to ']")
  end

  def toggle_theme
    theme_button.click
  end

  # What the toggle actually acts on: an explicit stamp if there is one, and
  # otherwise whatever the browser prefers. Asserting against the raw
  # data-theme attribute alone makes the test depend on which other test ran
  # first, because the choice is remembered in localStorage.
  def resolved_theme
    page.evaluate_script(<<~JS)
      document.documentElement.getAttribute('data-theme') ||
        (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    JS
  end

  def reset_theme_preference
    page.execute_script(<<~JS)
      try { window.localStorage.removeItem('flightdeck:theme'); } catch (error) {}
      document.documentElement.removeAttribute('data-theme');
    JS
    page.refresh
  end

  def expected_theme_label
    "Switch to #{resolved_theme == "dark" ? "light" : "dark"} theme"
  end

  def visible_theme_icons
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('.fd-theme-toggle svg'))
           .filter(function (icon) { return getComputedStyle(icon).display !== 'none' }).length
    JS
  end

  def pick_font(slug)
    find(".fd-font-picker select").select(Flightdeck::UiFonts.label(slug))
  end

  def font_stamp
    page.evaluate_script("document.documentElement.getAttribute('data-font')")
  end

  # The resolved --font-ui stack, which is what every rule in the stylesheet
  # actually reads.
  def rendered_ui_font
    page.evaluate_script("getComputedStyle(document.documentElement).getPropertyValue('--font-ui')")
  end

  # The first family in an element's computed stack: what it is really drawn
  # in, as opposed to what was asked for.
  def used_font_family(selector)
    page.evaluate_script(<<~JS).to_s.delete('"').strip
      getComputedStyle(document.querySelector('#{selector}')).fontFamily.split(',')[0]
    JS
  end

  # False until the woff2 has arrived and parsed, so it distinguishes "asked
  # for the family" from "is drawing in it".
  def font_loaded?(family)
    page.evaluate_script(%(document.fonts.check("14px '#{family}'")))
  end

  # The pick is remembered in localStorage, so without this a test inherits
  # whichever font the test before it chose.
  def reset_font_preference
    page.execute_script(<<~JS)
      try { window.localStorage.removeItem('flightdeck:font'); } catch (error) {}
    JS
    page.refresh
  end

  # Regression for the "Content missing" bug: a job link lives inside the
  # polling #fd-jobs frame, and its destination has no such frame. Without an
  # explicit escape, Turbo swaps "Content missing" into the frame instead of
  # navigating the page.
  test "clicking through from the overview to a job detail page" do
    create_ready_job(class_name: "SearchIndexJob", queue_name: "critical")
    create_finished_job(queue_name: "critical", finished_at: 10.minutes.ago)

    visit "/flightdeck"
    assert_selector ".fd-tile", count: 7

    within("#fd-overview-queues") { click_link "View all" }
    assert_current_path "/flightdeck/queues"

    visit "/flightdeck/jobs"
    click_link "SearchIndexJob"

    assert_selector ".fd-jd-head h2", text: "SearchIndexJob"
    assert_no_text "Content missing"
    assert_match %r{/flightdeck/jobs/\d+}, current_path
  end

  test "job links in the failed list open the detail page too" do
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob", exception_class: "Stripe::RateLimitError")

    visit "/flightdeck/jobs?state=failed"
    click_link "Billing::ChargeSubscriptionJob"

    assert_selector ".fd-error-box", text: "Stripe::RateLimitError"
    assert_no_text "Content missing"
  end

  # Regression for the theme bug: the stamp has to reach the shell, not just the
  # content area, in both directions.
  test "the theme toggle restyles the whole shell, sidebar included" do
    visit "/flightdeck"

    sidebar_before = background_of(".fd-side")
    topbar_before = background_of(".fd-topbar")

    toggle_theme
    assert_includes %w[light dark], theme_stamp

    wait_until(message: "the sidebar background never changed") { background_of(".fd-side") != sidebar_before }
    refute_equal topbar_before, background_of(".fd-topbar"), "the topbar must follow the theme too"

    # And back again, so neither direction is a one-way trip.
    stamped = theme_stamp
    toggle_theme
    wait_until(message: "the stamp never flipped back") { theme_stamp != stamped }
    wait_until(message: "the sidebar never returned") { background_of(".fd-side") == sidebar_before }
  end

  test "the theme toggle is an icon button whose label names what clicking does" do
    visit "/flightdeck"
    reset_theme_preference

    # The label has to describe the *action*, and stay true after toggling.
    label_before = theme_button[:"aria-label"]
    assert_match(/\ASwitch to (light|dark) theme\z/, label_before)
    assert_equal expected_theme_label, label_before

    # Icon only: no text, and exactly one of the two icons visible.
    assert_empty theme_button.text.strip
    assert_equal 1, visible_theme_icons, "exactly one of the sun/moon icons should be visible"

    toggle_theme
    wait_until(message: "the aria-label never followed the theme") { theme_button[:"aria-label"] != label_before }

    assert_equal expected_theme_label, theme_button[:"aria-label"]
    assert_equal 1, visible_theme_icons, "the icon should have swapped, not doubled up"
  end

  test "the theme choice survives a page navigation" do
    visit "/flightdeck"
    toggle_theme
    chosen = theme_stamp

    visit "/flightdeck/queues"

    assert_equal chosen, theme_stamp
  end

  # The whole point of switching on a custom property: no reload, and the face
  # really changes rather than the stamp changing under an unloaded font.
  test "picking a font restyles the shell immediately" do
    visit "/flightdeck"
    reset_font_preference

    before = rendered_ui_font
    assert_includes before, Flightdeck::UiFonts.label(Flightdeck::UiFonts::DEFAULT)

    pick_font("inter")

    assert_equal "inter", font_stamp
    wait_until(message: "the body never rendered in the picked face") { rendered_ui_font.include?("Inter") }
    assert_equal "Inter", used_font_family(".fd-nav-link"), "the sidebar should follow the pick too"
  end

  # Guards the whole chain per face: manifest entry, @font-face rule, relative
  # URL, and a woff2 the browser can actually parse. A missing or corrupt file
  # shows up as a silent fallback to system-ui, which no other test would see.
  test "every offered face is really loaded, not silently substituted" do
    visit "/flightdeck"

    Flightdeck::UiFonts::BUNDLED.each do |slug|
      family = Flightdeck::UiFonts.label(slug)
      pick_font(slug)

      wait_until(message: "#{family} never loaded") { font_loaded?(family) }
      assert_equal family, used_font_family("body"), "the body should be drawn in #{family}"
    end
  ensure
    reset_font_preference
  end

  test "the mono face is unaffected by the UI font" do
    visit "/flightdeck/jobs"
    reset_font_preference
    mono_before = used_font_family("table.fd-data th")

    pick_font("manrope")
    wait_until(message: "the UI font never changed") { rendered_ui_font.include?("Manrope") }

    assert_equal mono_before, used_font_family("table.fd-data th")
    assert_equal "IBM Plex Mono", mono_before
  end

  test "the font choice survives a page navigation" do
    visit "/flightdeck"
    pick_font("public-sans")

    visit "/flightdeck/queues"

    assert_equal "public-sans", font_stamp
    assert_equal "public-sans", find(".fd-font-picker select").value
  ensure
    reset_font_preference
  end

  test "retrying a failed job from the list shows a toast and drops the row" do
    job = create_failed_job(class_name: "WebhookDeliveryJob")

    visit "/flightdeck/jobs?state=failed"
    assert_selector "#fd-job-#{job.id}"

    accept_confirm { find("#fd-job-#{job.id}").click_link("Retry") }

    assert_selector "#fd-toasts .fd-toast", text: "Retried job ##{job.id}"
    assert_no_selector "#fd-job-#{job.id}"
    assert SolidQueue::ReadyExecution.exists?(job_id: job.id), "the job should be ready again"
  end

  test "the LIVE switch pauses and resumes polling" do
    create_ready_job

    visit "/flightdeck/jobs?state=ready"
    assert_selector "turbo-frame#fd-jobs"

    # Polling starts on: the frame acquires a src on its first tick.
    assert_equal "on", live_state

    find(".fd-live").click
    assert_equal "off", live_state
    assert_selector ".fd-live", text: "PAUSED"

    # While paused a new job must not appear on its own.
    create_ready_job(class_name: "AppearsWhilePausedJob")
    sleep 1.5
    assert_no_text "AppearsWhilePausedJob"

    # Resuming refreshes immediately rather than waiting out an interval.
    find(".fd-live").click
    assert_equal "on", live_state
    assert_text "AppearsWhilePausedJob"
  end

  test "the topbar clock ticks" do
    visit "/flightdeck"

    first = find(".fd-clock").text
    assert_match(/\A\d{2}:\d{2}:\d{2} \w+\z/, first)

    wait_until(timeout: 4, message: "the clock never advanced") { find(".fd-clock").text != first }
  end

  test "list rows show job arguments rather than the ActiveJob envelope" do
    create_ready_job(class_name: "SearchIndexJob",
                     arguments: { "arguments" => [ { "model" => "Product", "id" => 41_230 } ] })

    visit "/flightdeck/jobs?state=ready"

    assert_selector ".args", text: "Product"
    assert_no_selector ".args", text: "job_class"
  end
end
