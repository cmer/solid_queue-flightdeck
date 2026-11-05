# frozen_string_literal: true

require "test_helper"

class Flightdeck::JobActionsTest < FlightdeckIntegrationTest
  # --- single ---------------------------------------------------------------

  test "retrying a failed job moves it out of failed and back into ready" do
    job = create_failed_job

    post_fd "/flightdeck/jobs/#{job.id}/retry"

    assert_response :redirect
    refute in_table?(SolidQueue::FailedExecution, job), "the failure row should be gone"
    assert in_table?(SolidQueue::ReadyExecution, job), "the job should be ready again"
    assert_equal :ready, job_state(job)
  end

  test "discarding a failed job removes the job entirely" do
    job = create_failed_job

    post_fd "/flightdeck/jobs/#{job.id}/discard", params: { state: "failed" }

    refute in_table?(SolidQueue::FailedExecution, job)
    assert_nil SolidQueue::Job.find_by(id: job.id), "the job row should be gone"
  end

  test "discarding works for ready, scheduled and blocked jobs too" do
    ready = create_ready_job
    scheduled = create_scheduled_job
    blocked = create_blocked_job

    [ [ ready, "ready" ], [ scheduled, "scheduled" ], [ blocked, "blocked" ] ].each do |job, state|
      post_fd "/flightdeck/jobs/#{job.id}/discard", params: { state: state }

      assert_nil SolidQueue::Job.find_by(id: job.id), "#{state} job should have been discarded"
    end
  end

  test "acting on a job that has already moved on reports it instead of failing" do
    job = create_failed_job
    SolidQueue::FailedExecution.delete_all

    post_fd "/flightdeck/jobs/#{job.id}/retry"

    assert_response :redirect
    assert_match(/no longer failed/i, flash[:alert].to_s)
  end

  test "a job being executed cannot be discarded" do
    job = create_claimed_job

    post_fd "/flightdeck/jobs/#{job.id}/discard", params: { state: "failed" }

    assert_not_nil SolidQueue::Job.find_by(id: job.id), "an in-progress job must survive"
  end

  # --- selected -------------------------------------------------------------

  test "retrying selected jobs retries only those jobs" do
    selected = 2.times.map { create_failed_job }
    untouched = create_failed_job

    post_fd "/flightdeck/jobs/retry", params: { job_ids: selected.map(&:id), state: "failed" }

    selected.each do |job|
      assert in_table?(SolidQueue::ReadyExecution, job), "selected job #{job.id} should be ready"
    end
    assert in_table?(SolidQueue::FailedExecution, untouched), "unselected job must be left alone"
  end

  test "discarding selected jobs discards only those jobs" do
    selected = create_failed_job
    untouched = create_failed_job

    post_fd "/flightdeck/jobs/discard", params: { job_ids: [ selected.id ], state: "failed" }

    assert_nil SolidQueue::Job.find_by(id: selected.id)
    assert_not_nil SolidQueue::Job.find_by(id: untouched.id)
  end

  test "selected ids are re-checked against the live table" do
    stale = create_failed_job
    live = create_failed_job
    SolidQueue::FailedExecution.where(job_id: stale.id).delete_all

    post_fd "/flightdeck/jobs/retry", params: { job_ids: [ stale.id, live.id ], state: "failed" }

    assert in_table?(SolidQueue::ReadyExecution, live)
    assert_match(/already moved on/i, flash[:notice].to_s)
  end

  test "an empty selection is refused" do
    post_fd "/flightdeck/jobs/retry", params: { job_ids: [], state: "failed" }

    assert_match(/nothing selected/i, flash[:alert].to_s)
  end

  test "a selection larger than the bulk limit is refused outright" do
    Flightdeck.config.bulk_action_limit = 2
    jobs = 3.times.map { create_failed_job }

    post_fd "/flightdeck/jobs/retry", params: { job_ids: jobs.map(&:id), state: "failed" }

    assert_match(/at most 2 jobs/i, flash[:alert].to_s)
    jobs.each { |job| assert in_table?(SolidQueue::FailedExecution, job) }
  ensure
    Flightdeck.config.bulk_action_limit = 1_000
  end

  # --- all matching ---------------------------------------------------------

  test "retrying all matching leaves jobs outside the failed_within window alone" do
    recent = create_failed_job(failed_at: 30.minutes.ago)
    older = create_failed_job(failed_at: 2.hours.ago)

    post_fd "/flightdeck/jobs/retry", params: { scope: "all", state: "failed", failed_within: "1h" }

    assert in_table?(SolidQueue::ReadyExecution, recent), "the job in the window should be retried"
    assert in_table?(SolidQueue::FailedExecution, older), "the older job should still be failed"
  end

  test "discarding all matching leaves jobs outside the failed_within window alone" do
    recent = create_failed_job(failed_at: 30.minutes.ago)
    older = create_failed_job(failed_at: 2.hours.ago)

    post_fd "/flightdeck/jobs/discard", params: { scope: "all", state: "failed", failed_within: "1h" }

    assert_nil SolidQueue::Job.find_by(id: recent.id)
    assert in_table?(SolidQueue::FailedExecution, older), "the older job should still be failed"
  end

  test "applying to all matching respects the filter that was on screen" do
    matching = 2.times.map { create_failed_job(class_name: "AlphaJob") }
    other = create_failed_job(class_name: "BetaJob")

    post_fd "/flightdeck/jobs/retry", params: { scope: "all", state: "failed", class_name: "AlphaJob" }

    matching.each { |job| assert in_table?(SolidQueue::ReadyExecution, job) }
    assert in_table?(SolidQueue::FailedExecution, other), "a job outside the filter must not be touched"
  end

  test "applying to all matching stops at the configured limit and reports the remainder" do
    Flightdeck.config.bulk_action_limit = 2
    5.times { create_failed_job }

    post_fd "/flightdeck/jobs/retry", params: { scope: "all", state: "failed" }

    assert_equal 2, SolidQueue::ReadyExecution.count, "should have stopped at the limit"
    assert_equal 3, SolidQueue::FailedExecution.count, "the rest must be left for a follow-up run"
    assert_match(/Retried 2 of ~5 — continue\?/, flash[:notice].to_s)
  ensure
    Flightdeck.config.bulk_action_limit = 1_000
  end

  test "re-submitting after a capped run continues where it left off" do
    Flightdeck.config.bulk_action_limit = 2
    4.times { create_failed_job }

    3.times { post_fd "/flightdeck/jobs/retry", params: { scope: "all", state: "failed" } }

    assert_equal 0, SolidQueue::FailedExecution.count
    assert_equal 4, SolidQueue::ReadyExecution.count
  ensure
    Flightdeck.config.bulk_action_limit = 1_000
  end

  test "discarding all matching removes every matching job" do
    3.times { create_failed_job(class_name: "AlphaJob") }
    keep = create_failed_job(class_name: "BetaJob")

    post_fd "/flightdeck/jobs/discard", params: { scope: "all", state: "failed", class_name: "AlphaJob" }

    assert_equal 1, SolidQueue::Job.count
    assert_not_nil SolidQueue::Job.find_by(id: keep.id)
  end

  # --- turbo streams --------------------------------------------------------

  test "a turbo stream request answers with a toast and a refreshed list" do
    job = create_failed_job

    post_fd "/flightdeck/jobs/#{job.id}/retry",
            params: { state: "failed" },
            headers: turbo_stream_headers

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=append][target=fd-toasts]"
    assert_select "turbo-stream[action=replace][target=fd-jobs]"
    assert_includes response.body, "Retried job ##{job.id}."
    assert_includes response.body, %(data-controller="toast")
  end

  test "a failing action answers with an error toast" do
    job = create_failed_job
    SolidQueue::FailedExecution.delete_all

    post_fd "/flightdeck/jobs/#{job.id}/retry",
            params: { state: "failed" },
            headers: turbo_stream_headers

    assert_response :success
    assert_select "turbo-stream[action=append][target=fd-toasts]"
    assert_includes response.body, "fd-toast error"
  end

  test "the refreshed list in a turbo stream reflects the action that just ran" do
    retried = create_failed_job
    remaining = create_failed_job

    post_fd "/flightdeck/jobs/#{retried.id}/retry",
            params: { state: "failed" },
            headers: turbo_stream_headers

    ids = response.body.scan(/id="fd-job-(\d+)"/).flatten.map(&:to_i)
    assert_equal [ remaining.id ], ids
  end

  # --- CSRF -----------------------------------------------------------------

  test "a post without a CSRF token is rejected" do
    job = create_failed_job

    post_fd "/flightdeck/jobs/#{job.id}/retry", csrf: false

    assert_response :unprocessable_content
    assert in_table?(SolidQueue::FailedExecution, job), "the job must not have been retried"
  end

  test "actions still require authentication" do
    job = create_failed_job

    post "/flightdeck/jobs/#{job.id}/retry"

    assert_response :unauthorized
    assert in_table?(SolidQueue::FailedExecution, job)
  end
end
