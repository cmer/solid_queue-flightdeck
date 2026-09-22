# frozen_string_literal: true

require "test_helper"

# Regression cover for the "Content missing" class of bug.
#
# Every panel on the dashboard lives in a polling <turbo-frame>. A link inside
# one of those frames navigates the *frame* by default, so if its destination
# has no frame with a matching id, Turbo renders "Content missing" instead of
# the page. Links that leave a panel must therefore say so — either per link
# with data-turbo-frame="_top", or once on a frame whose links all navigate away
# via target="_top".
class Flightdeck::FrameNavigationTest < FlightdeckIntegrationTest
  # Panels where every link goes to another page.
  TOP_LEVEL_FRAMES = {
    "/flightdeck" => %w[fd-tiles fd-throughput fd-completion fd-overview-queues fd-overview-failures fd-fleet],
    "/flightdeck/queues" => %w[fd-queues],
    "/flightdeck/processes" => %w[fd-processes],
    "/flightdeck/recurring_tasks" => %w[fd-recurring]
  }.freeze

  test "panel frames whose links all navigate away target the whole page" do
    seed_everything

    TOP_LEVEL_FRAMES.each do |path, frame_ids|
      get_fd path

      frame_ids.each do |id|
        assert_select "turbo-frame##{id}[target=_top]", 1,
                      "#{id} on #{path} must let its links escape the frame"
      end
    end
  end

  # The jobs frame is the exception: its pager must navigate the frame itself,
  # so escaping is per link rather than frame-wide.
  test "the jobs frame keeps pagination in-frame" do
    30.times { create_ready_job }
    Flightdeck.config.per_page = 5

    get_fd "/flightdeck/jobs?state=ready"

    assert_select "turbo-frame#fd-jobs[target=_top]", 0,
                  "pagination must stay inside the jobs frame"
    assert_select "turbo-frame#fd-jobs a[href*='before_id']", minimum: 1
  ensure
    Flightdeck.config.per_page = 25
  end

  test "job links inside the jobs frame escape it" do
    create_ready_job(class_name: "AlphaJob")

    get_fd "/flightdeck/jobs?state=ready"

    assert_select "turbo-frame#fd-jobs td.cls a[data-turbo-frame=_top]", 1,
                  "a job link must load the detail page, not swap it into the frame"
  end

  test "job links in the failed list escape the frame too" do
    create_failed_job(class_name: "AlphaJob")

    get_fd "/flightdeck/jobs?state=failed"

    assert_select "turbo-frame#fd-jobs td.cls a[data-turbo-frame=_top]", 1
  end

  test "the batches frame keeps pagination in-frame" do
    30.times { |i| create_batch(description: "Batch #{i}") }
    Flightdeck.config.per_page = 5

    get_fd "/flightdeck/batches"

    assert_select "turbo-frame#fd-batches[target=_top]", 0,
                  "pagination must stay inside the batches frame"
    assert_select "turbo-frame#fd-batches a[href*='before_id']", minimum: 1
  ensure
    Flightdeck.config.per_page = 25
  end

  test "batch links inside the batches frame escape it" do
    create_batch(description: "Nightly import")

    get_fd "/flightdeck/batches"

    assert_select "turbo-frame#fd-batches td.cls a[data-turbo-frame=_top]", 1
  end

  test "the batch show frame lets its links escape" do
    batch = create_finished_batch(description: "Nightly import")

    get_fd "/flightdeck/batches/#{batch.id}"

    assert_select "turbo-frame#fd-batch[target=_top]", 1
  end

  # The actual failure mode: a link's destination has no frame with its id.
  test "no link inside a frame points at a page that lacks that frame" do
    seed_everything

    ([ "/flightdeck/jobs", "/flightdeck/jobs?state=failed", "/flightdeck/batches" ] + TOP_LEVEL_FRAMES.keys).each do |path|
      get_fd path
      document = Nokogiri::HTML(response.body)

      document.css("turbo-frame[id]").each do |frame|
        next if frame["target"] == "_top"

        frame.css("a[href]").each do |link|
          next if link["data-turbo-frame"] == "_top"
          next if link["data-turbo-method"].present?

          href = link["href"]
          next unless href.start_with?("/flightdeck")

          get_fd href
          assert_includes response.body, %(id="#{frame["id"]}"),
                          "#{path}: link to #{href} sits in ##{frame["id"]} but that page has no such " \
                          "frame — Turbo would render \"Content missing\""
          get_fd path
        end
      end
    end
  end

  private
    def seed_everything
      create_full_scenario
      create_fleet
      task = create_recurring_task(key: "digest")
      record_recurring_run(task, run_at: 1.hour.ago)
      create_finished_job(queue_name: "critical", finished_at: 30.minutes.ago)
      create_finished_batch(description: "Nightly import")
    end
end
