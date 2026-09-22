# frozen_string_literal: true

require "test_helper"

class Flightdeck::JobDetailTest < ActiveSupport::TestCase
  test "resolves state and error details for a failed job" do
    job = create_failed_job(exception_class: "Stripe::RateLimitError", message: "429 slow down")

    detail = Flightdeck::JobDetail.find(job.id)

    assert_equal :failed, detail.state
    assert detail.retryable?
    assert detail.discardable?
    assert_equal "Stripe::RateLimitError", detail.error_class
    assert_equal "429 slow down", detail.error_message
  end

  test "highlights application frames and leaves gem frames alone" do
    job = create_failed_job(backtrace: [
      "gems/stripe-12.1.0/lib/stripe/api_requestor.rb:412:in `handle_error_response'",
      "app/jobs/billing/charge_subscription_job.rb:14:in `perform'",
      "/usr/lib/ruby/3.3.0/net/http.rb:1570:in `request'",
      "lib/my_app/client.rb:9:in `call'"
    ])

    frames = Flightdeck::JobDetail.find(job.id).backtrace_frames

    assert_equal [ false, true, false, true ], frames.map { |frame| frame[:app] }
  end

  test "honours the configured backtrace line limit" do
    job = create_failed_job(backtrace: Array.new(120) { |i| "app/frame_#{i}.rb:1:in `call'" })

    original = Flightdeck.config.backtrace_lines
    Flightdeck.config.backtrace_lines = 10

    detail = Flightdeck::JobDetail.find(job.id)

    assert_equal 10, detail.backtrace.size
    assert_equal 120, detail.backtrace_total
    assert detail.backtrace_truncated?
  ensure
    Flightdeck.config.backtrace_lines = original
  end

  test "pretty-prints the stored arguments without deserializing them" do
    job = create_failed_job(class_name: "Billing::ChargeSubscriptionJob",
                            arguments: { "arguments" => [ { "subscription_id" => 48_211 } ] })

    detail = Flightdeck::JobDetail.find(job.id)

    assert_includes detail.arguments_json, %("subscription_id": 48211)
    assert_includes detail.arguments_json, "\n", "arguments should be pretty-printed"
    refute detail.arguments_truncated?
  end

  test "truncates very large arguments for display but reports the real size" do
    job = create_ready_job(arguments: { "arguments" => [ "z" * 40_000 ] })

    detail = Flightdeck::JobDetail.find(job.id)

    assert detail.arguments_truncated?
    assert_equal Flightdeck::JobDetail::ARGUMENTS_DISPLAY_LIMIT, detail.arguments_preview.bytesize
    assert_operator detail.arguments_bytes, :>, Flightdeck::JobDetail::ARGUMENTS_DISPLAY_LIMIT
  end

  test "builds a timeline from timestamps that actually exist" do
    job = create_failed_job

    labels = Flightdeck::JobDetail.find(job.id).timeline.map(&:label)

    assert_equal [ "Enqueued", "Failed", "Awaiting decision" ], labels
  end

  test "a scheduled job's timeline shows the schedule but no execution steps" do
    job = create_scheduled_job(scheduled_at: 2.hours.from_now)

    events = Flightdeck::JobDetail.find(job.id).timeline

    assert_equal [ "Enqueued", "Scheduled" ], events.map(&:label)
    assert_equal "not yet due", events.last.detail
  end

  test "a finished job is finished regardless of leftover execution rows" do
    job = create_finished_job

    detail = Flightdeck::JobDetail.find(job.id)

    assert_equal :finished, detail.state
    refute detail.retryable?
    refute detail.discardable?
    assert_includes detail.timeline.map(&:label), "Finished"
  end

  test "a job that belongs to a batch exposes the batch on the detail object" do
    batch = create_batch(description: "Nightly import", total_jobs: 1)
    job = create_ready_job
    add_to_batch(batch, job, pending: true)

    detail = Flightdeck::JobDetail.find(job.id)

    assert detail.batched?
    assert_equal batch.id, detail.batch.id
    assert_equal "Nightly import", detail.batch.title
    assert_equal :enqueued, detail.batch.status
  end

  test "a job with no batch is not batched" do
    job = create_ready_job

    refute Flightdeck::JobDetail.find(job.id).batched?
  end

  test "an in-progress job names the process that claimed it" do
    process = create_process(name: "jobs-01", pid: 4172)
    job = create_claimed_job(process: process)

    detail = Flightdeck::JobDetail.find(job.id)

    assert_equal :in_progress, detail.state
    assert_equal "jobs-01 · pid 4172", detail.process_label
    refute detail.discardable?, "a job being executed cannot be discarded"
  end
end
