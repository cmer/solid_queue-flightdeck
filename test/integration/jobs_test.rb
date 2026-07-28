# frozen_string_literal: true

require "test_helper"

class Flightdeck::JobsTest < FlightdeckIntegrationTest
  test "the index requires authentication like every other page" do
    get "/flightdeck/jobs"

    assert_response :unauthorized
  end

  test "each state tab lists exactly the jobs in that state" do
    scenario = create_full_scenario

    {
      ready: :ready, scheduled: :scheduled, in_progress: :in_progress,
      blocked: :blocked, finished: :finished, failed: :failed
    }.each do |tab, state|
      get_fd "/flightdeck/jobs?state=#{tab}"

      assert_response :success
      assert_equal [ scenario[state].id ], job_ids_in_response, "the #{tab} tab listed the wrong jobs"
    end
  end

  test "the all tab lists every job and labels each one's state" do
    scenario = create_full_scenario

    get_fd "/flightdeck/jobs"

    assert_response :success
    assert_equal scenario.values.map(&:id).sort, job_ids_in_response.sort
    assert_includes response.body, "FAILED"
    assert_includes response.body, "SCHEDULED"
    assert_includes response.body, "IN PROGRESS"
  end

  test "the state tabs carry counts" do
    create_full_scenario

    get_fd "/flightdeck/jobs"

    assert_select ".fd-statetabs a", count: Flightdeck::JobsQuery::STATES.size
    assert_select ".fd-statetabs a.on", text: /All/
  end

  test "filters by class and queue compose, and survive into the pagination links" do
    match = create_ready_job(class_name: "AlphaJob", queue_name: "critical")
    create_ready_job(class_name: "AlphaJob", queue_name: "low")
    create_ready_job(class_name: "BetaJob", queue_name: "critical")

    get_fd "/flightdeck/jobs?state=ready&class_name=AlphaJob&queue_name=critical"

    assert_response :success
    assert_equal [ match.id ], job_ids_in_response
    assert_select ".fd-chip", text: /clear filters/
  end

  test "search narrows the list by job class prefix" do
    match = create_ready_job(class_name: "Billing::ChargeJob")
    create_ready_job(class_name: "WebhookJob")

    get_fd "/flightdeck/jobs?state=ready&q=Billing"

    assert_equal [ match.id ], job_ids_in_response
  end

  test "keyset pagination walks three pages without overlap or skipped rows" do
    jobs = 7.times.map { create_ready_job }
    Flightdeck.config.per_page = 3

    seen = []
    path = "/flightdeck/jobs?state=ready"

    3.times do
      get_fd path
      assert_response :success
      seen.concat(job_ids_in_response)

      # Read the pager link specifically: the frame's refresh URL also carries
      # the current cursor, and would otherwise be picked up instead.
      cursor = response.body[/href="[^"]*before_id=(\d+)/, 1]
      break if cursor.nil?

      path = "/flightdeck/jobs?state=ready&before_id=#{cursor}"
    end

    assert_equal jobs.map(&:id).sort.reverse, seen
    assert_equal seen.uniq, seen
  ensure
    Flightdeck.config.per_page = 25
  end

  test "a capped count is rendered with a plus rather than a wrong number" do
    3.times { create_ready_job }
    Flightdeck.config.count_cap = 2

    get_fd "/flightdeck/jobs?state=ready"

    assert_match(/2\+/, response.body)
    assert_includes response.body, "counts capped at"
  ensure
    Flightdeck.config.count_cap = 500_000
  end

  test "the jobs table lives in a polling turbo frame that keeps the current URL" do
    create_ready_job

    get_fd "/flightdeck/jobs?state=ready&queue_name=default"

    assert_select "turbo-frame#fd-jobs" do |frames|
      frame = frames.first
      assert_equal "refresh", frame["data-controller"]
      assert_equal (Flightdeck.config.poll_interval.to_f * 1000).round.to_s,
                   frame["data-refresh-interval-value"]
      assert_includes frame["data-refresh-url-value"], "state=ready"
      assert_includes frame["data-refresh-url-value"], "queue_name=default"
    end
  end

  test "an empty list says so instead of rendering a bare table" do
    get_fd "/flightdeck/jobs?state=ready"

    assert_select ".fd-empty", text: /No jobs/
  end

  test "the failed tab groups rows by exception class and offers bulk actions" do
    create_failed_job(exception_class: "Stripe::RateLimitError", class_name: "ChargeJob")
    create_failed_job(exception_class: "Stripe::RateLimitError", class_name: "ChargeJob")
    create_failed_job(exception_class: "Net::ReadTimeout", class_name: "WebhookJob")

    get_fd "/flightdeck/jobs?state=failed"

    assert_response :success
    assert_select ".fd-group-row", count: 2
    assert_select ".fd-group-row td", text: /STRIPE::RATELIMITERROR · 2 jobs/
    assert_select ".fd-group-row td", text: /NET::READTIMEOUT · 1 job/
    assert_select ".fd-bulkbar"
    assert_select "input[type=checkbox][name='job_ids[]']", count: 3
  end

  # The bulk bar is one form posting to the retry endpoint, so every button that
  # is not a retry must carry its own formaction. A neutral "apply to all"
  # button once inherited the form action and retried when discard was meant.
  test "every destructive button in the bulk bar posts to the discard endpoint" do
    2.times { create_failed_job }

    get_fd "/flightdeck/jobs?state=failed"

    assert_response :success
    assert_select ".fd-bulkbar button[formaction^=?]", "/flightdeck/jobs/discard", count: 2
    assert_select ".fd-bulkbar button[name=scope][value=all]", count: 2 do |buttons|
      assert_equal 1, buttons.count { |b| b["formaction"].to_s.start_with?("/flightdeck/jobs/discard") },
                   "one all-matching button must discard"
      assert_equal 1, buttons.count { |b| b["formaction"].blank? },
                   "one all-matching button must fall through to the form's retry action"
    end
  end

  test "the job detail page renders the error, arguments, metadata and timeline" do
    job = create_failed_job(class_name: "Billing::ChargeSubscriptionJob",
                            queue_name: "critical",
                            exception_class: "Stripe::RateLimitError",
                            message: "429 slow down",
                            arguments: { "arguments" => [ { "subscription_id" => 48_211 } ] })

    get_fd "/flightdeck/jobs/#{job.id}"

    assert_response :success
    assert_select ".fd-jd-head h2", text: "Billing::ChargeSubscriptionJob"
    assert_select ".fd-error-box .msg", text: /Stripe::RateLimitError.*429 slow down/m
    assert_select "details.fd-bt .app-line", text: /charge_subscription_job\.rb/
    assert_select "pre.fd-code", text: /"subscription_id": 48211/
    assert_select ".fd-meta-grid", text: /critical/
    assert_select ".fd-timeline .fd-tl-item", minimum: 2
  end

  test "the detail page offers retry and discard for a failed job" do
    job = create_failed_job

    get_fd "/flightdeck/jobs/#{job.id}"

    assert_select "form[action^=?]", "/flightdeck/jobs/#{job.id}/retry"
    assert_select "form[action^=?]", "/flightdeck/jobs/#{job.id}/discard"
  end

  test "the detail page offers neither action for a job being executed" do
    job = create_claimed_job

    get_fd "/flightdeck/jobs/#{job.id}"

    assert_response :success
    assert_select "form[action^=?]", "/flightdeck/jobs/#{job.id}/retry", count: 0
    assert_select "form[action^=?]", "/flightdeck/jobs/#{job.id}/discard", count: 0
  end

  test "a missing job redirects back to the list rather than 500ing" do
    get_fd "/flightdeck/jobs/999999"

    assert_redirected_to "/flightdeck/jobs"
  end

  test "an unknown state redirects to the default list" do
    get_fd "/flightdeck/jobs?state=nonsense"

    assert_redirected_to "/flightdeck/jobs"
  end
end
