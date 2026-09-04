# frozen_string_literal: true

require "test_helper"

class Flightdeck::OverviewTest < FlightdeckIntegrationTest
  test "requires authentication" do
    get "/flightdeck"

    assert_response :unauthorized
  end

  # --- empty database -------------------------------------------------------

  test "renders every panel against a completely empty database" do
    get_fd "/flightdeck"

    assert_response :success
    assert_select ".fd-tile", count: 7
    assert_select "svg.fd-chart", count: 2
    assert_select "#fd-overview-queues .fd-empty"
    assert_select "#fd-overview-failures .fd-empty"
    assert_select "#fd-fleet .fd-empty"
  end

  test "empty tiles read as zero rather than blank" do
    get_fd "/flightdeck"

    assert_select ".fd-tile", text: /Processed · 24h\s*0/
    assert_select ".fd-tile", text: /Oldest ready\s*—/
    assert_select ".fd-tile", text: /nothing scheduled/
  end

  # --- seeded ---------------------------------------------------------------

  test "tiles report the real numbers" do
    12.times { create_finished_job(finished_at: 2.hours.ago) }
    3.times { create_failed_job }
    4.times { create_ready_job(created_at: 90.seconds.ago) }
    2.times { create_scheduled_job(scheduled_at: 10.minutes.from_now) }
    5.times { create_blocked_job }
    worker = create_worker(threads: 10)
    create_claimed_job(process: worker)

    get_fd "/flightdeck"

    assert_response :success
    assert_select ".fd-tile", text: /Processed · 24h\s*12/
    assert_select ".fd-tile", text: /Failed · 24h\s*3/
    assert_select ".fd-tile", text: /Ready now\s*4/
    assert_select ".fd-tile", text: /Blocked\s*5/
    assert_select ".fd-tile", text: /Scheduled\s*2/
    assert_select ".fd-tile", text: %r{In progress\s*1\s*/ 10 slots}
    assert_includes response.body, "10% utilization"
  end

  test "the failure rate is computed against everything that finished" do
    9.times { create_finished_job(finished_at: 1.hour.ago) }
    1.times { create_failed_job }

    get_fd "/flightdeck"

    assert_includes response.body, "10.0% failure rate"
  end

  test "the processed delta compares against the prior 24h window" do
    10.times { create_finished_job(finished_at: 2.hours.ago) }
    5.times { create_finished_job(finished_at: 30.hours.ago) }

    get_fd "/flightdeck"

    assert_includes response.body, "100.0% vs prior 24h"
  end

  test "no prior window is stated as such rather than shown as a percentage" do
    3.times { create_finished_job(finished_at: 1.hour.ago) }

    get_fd "/flightdeck"

    assert_includes response.body, "no prior window to compare"
  end

  test "the oldest ready age comes from the oldest waiting job" do
    create_ready_job(created_at: 5.minutes.ago)
    create_ready_job(created_at: 10.seconds.ago)

    get_fd "/flightdeck"

    assert_select ".fd-tile", text: /Oldest ready\s*5m/
  end

  test "the scheduled tile counts down to the next due job" do
    create_scheduled_job(scheduled_at: 45.seconds.from_now)

    get_fd "/flightdeck"

    assert_includes response.body, "next due in"
  end

  test "a dead worker's threads are not counted as capacity" do
    create_worker(pid: 1, threads: 10)
    create_worker(pid: 2, threads: 8, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)

    get_fd "/flightdeck"

    assert_select ".fd-tile .val small", text: "/ 10 slots",
                  count: 1, message: "capacity must exclude workers that stopped reporting"
  end

  test "worker capacity is omitted when no worker reports a thread pool" do
    create_process(kind: "Worker", metadata: { "queues" => "*" })
    create_claimed_job

    get_fd "/flightdeck"

    assert_includes response.body, "no worker capacity reported"
    assert_select ".fd-tile .val small", text: /slots/, count: 0
  end

  # --- charts ---------------------------------------------------------------

  test "the throughput chart draws a bar per bucket with hover titles" do
    5.times { create_finished_job(finished_at: 90.minutes.ago) }
    create_failed_job

    get_fd "/flightdeck"

    assert_select "#fd-throughput svg.fd-chart"
    assert_select "#fd-throughput rect.fd-chart-bar-succeeded", minimum: 1
    assert_select "#fd-throughput title", minimum: 24
    assert_select "#fd-throughput .fd-legend", text: /Succeeded.*Failed/m
  end

  test "the completion chart is labelled as time to completion, never latency" do
    create_job(created_at: 90.minutes.ago, finished_at: 89.minutes.ago)

    get_fd "/flightdeck"

    assert_select "#fd-completion h3", text: "Time to completion"
    refute_match(/time.to.start/i, response.body)
    assert_select "#fd-completion path.fd-chart-line", minimum: 1
  end

  test "the range control switches the window" do
    get_fd "/flightdeck?range=1h"

    assert_response :success
    assert_select ".fd-seg a.on", text: "1H"
    assert_select "#fd-throughput .sub", text: /per 5 minutes/
    assert_select "#fd-throughput rect.fd-chart-bar-succeeded, #fd-throughput title", minimum: 12
  end

  test "the seven day range uses six hour buckets" do
    get_fd "/flightdeck?range=7d"

    assert_select ".fd-seg a.on", text: "7D"
    assert_select "#fd-throughput .sub", text: /per 6 hours/
  end

  test "an unknown range falls back to the default window" do
    get_fd "/flightdeck?range=nonsense"

    assert_response :success
    assert_select ".fd-seg a.on", text: "24H"
  end

  test "the purge cliff is annotated when retention is shorter than the window" do
    with_retention(1.day) do
      get_fd "/flightdeck?range=7d"

      assert_select ".fd-chart-note", text: /oldest buckets undercount/
    end
  end

  test "no purge annotation when retention covers the window" do
    with_retention(30.days) do
      get_fd "/flightdeck?range=7d"

      assert_select ".fd-chart-note", text: /undercount/, count: 0
    end
  end

  # --- panels ---------------------------------------------------------------

  test "the queues mini-table shows depth, latency, a sparkline and a depth bar" do
    3.times { create_ready_job(queue_name: "critical", created_at: 2.minutes.ago) }
    create_ready_job(queue_name: "low")
    create_finished_job(queue_name: "critical", finished_at: 90.minutes.ago)

    get_fd "/flightdeck"

    assert_select "#fd-overview-queues tbody tr", count: 2
    assert_select "#fd-overview-queues svg.fd-sparkline", minimum: 1
    assert_select "#fd-overview-queues .fd-depth-bar", count: 2
  end

  test "a paused queue is flagged in the mini-table" do
    create_ready_job(queue_name: "webhooks")
    SolidQueue::Queue.new("webhooks").pause

    get_fd "/flightdeck"

    assert_select "#fd-overview-queues .fd-pill.paused", text: "PAUSED"
  end

  test "recent failures list the newest five, linking to the job" do
    7.times { |i| create_failed_job(class_name: "Boom#{i}Job", exception_class: "Net::ReadTimeout", message: "late") }

    get_fd "/flightdeck"

    assert_select "#fd-overview-failures tbody tr", count: 5
    assert_select "#fd-overview-failures a[href^='/flightdeck/jobs/']", minimum: 5
    assert_select "#fd-overview-failures .args", text: /Net::ReadTimeout: late/
    assert_select "#fd-overview-failures a", text: /View all 7/
  end

  test "the fleet strip shows a chip per process with its heartbeat LED" do
    create_fleet
    create_worker(pid: 5501, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)

    get_fd "/flightdeck"

    assert_select "#fd-fleet .fd-proc-chip", count: 5
    assert_select "#fd-fleet .fd-led.fresh", count: 4
    assert_select "#fd-fleet .fd-led.dead", count: 1
  end

  # --- polling --------------------------------------------------------------

  test "panels poll at the poll interval and charts at the chart interval" do
    get_fd "/flightdeck"

    poll = (Flightdeck.config.poll_interval.to_f * 1000).round.to_s
    charts = (Flightdeck.config.chart_poll_interval.to_f * 1000).round.to_s

    assert_select "turbo-frame#fd-tiles[data-refresh-interval-value=?]", poll
    assert_select "turbo-frame#fd-overview-queues[data-refresh-interval-value=?]", poll
    assert_select "turbo-frame#fd-overview-failures[data-refresh-interval-value=?]", poll
    assert_select "turbo-frame#fd-fleet[data-refresh-interval-value=?]", poll
    assert_select "turbo-frame#fd-throughput[data-refresh-interval-value=?]", charts
    assert_select "turbo-frame#fd-completion[data-refresh-interval-value=?]", charts
  end

  test "each frame refreshes the URL it is showing, range included" do
    get_fd "/flightdeck?range=1h"

    assert_select "turbo-frame#fd-throughput[data-refresh-url-value=?]", "/flightdeck/?range=1h"
  end

  private
    def with_retention(duration)
      original = SolidQueue.clear_finished_jobs_after
      SolidQueue.clear_finished_jobs_after = duration
      yield
    ensure
      SolidQueue.clear_finished_jobs_after = original
    end
end
