# frozen_string_literal: true

require "test_helper"

class Flightdeck::BatchesTest < FlightdeckIntegrationTest
  test "the index requires authentication" do
    get "/flightdeck/batches"

    assert_response :unauthorized
  end

  test "the sidebar links to batches when the schema is present" do
    create_batch(description: "Nightly import")

    get_fd "/flightdeck/jobs"

    assert_select ".fd-nav-link[href=?]", "/flightdeck/batches"
  end

  test "the sidebar hides batches when they are unavailable" do
    with_batches_unavailable do
      get_fd "/flightdeck/jobs"

      assert_select ".fd-nav-link[href=?]", "/flightdeck/batches", count: 0
    end
  end

  test "visiting batches when unavailable redirects to the overview" do
    with_batches_unavailable do
      get_fd "/flightdeck/batches"

      assert_redirected_to "/flightdeck/"
    end
  end

  test "each state tab lists the matching batches" do
    running = create_batch(description: "Running import", total_jobs: 1)
    add_to_batch(running, create_ready_job, pending: true)
    completed = create_finished_batch(description: "Completed import")
    failed = create_failed_batch(description: "Failed import")

    get_fd "/flightdeck/batches?state=unfinished"
    assert_equal [ running.id ], batch_ids_in_response

    get_fd "/flightdeck/batches?state=completed"
    assert_equal [ completed.id ], batch_ids_in_response

    get_fd "/flightdeck/batches?state=failed"
    assert_equal [ failed.id ], batch_ids_in_response
  end

  test "the all tab lists every batch and labels its status" do
    create_batch(description: "Running import")
    create_finished_batch(description: "Completed import")
    create_failed_batch(description: "Failed import")

    get_fd "/flightdeck/batches"

    assert_response :success
    assert_includes response.body, "ENQUEUED"
    assert_includes response.body, "COMPLETED"
    assert_includes response.body, "FAILED"
    assert_select ".fd-statetabs a", count: Flightdeck::BatchesQuery::STATES.size
  end

  test "an empty list says so" do
    get_fd "/flightdeck/batches"

    assert_select ".fd-empty", text: /No batches/
  end

  test "the list lives in a polling turbo frame" do
    create_batch

    get_fd "/flightdeck/batches?state=unfinished"

    assert_select "turbo-frame#fd-batches" do |frames|
      frame = frames.first
      assert_equal "refresh", frame["data-controller"]
      assert_includes frame["data-refresh-url-value"], "state=unfinished"
    end
  end

  test "keyset pagination walks pages" do
    batches = 7.times.map { |i| create_batch(description: "Batch #{i}") }
    Flightdeck.config.per_page = 3

    seen = []
    path = "/flightdeck/batches"

    3.times do
      get_fd path
      assert_response :success
      seen.concat(batch_ids_in_response)

      cursor = response.body[/href="[^"]*before_id=(\d+)/, 1]
      break if cursor.nil?

      path = "/flightdeck/batches?before_id=#{cursor}"
    end

    assert_equal batches.map(&:id).sort.reverse, seen
  ensure
    Flightdeck.config.per_page = 25
  end

  test "the detail page shows progress, jobs and callback class names" do
    batch = create_batch(
      description: "Nightly billing sweep",
      total_jobs: 2,
      on_finish: { "job_class" => "NotifyBillingFinishedJob" },
      metadata: { "user_id" => 42 }
    )
    ready = create_ready_job(class_name: "Billing::ChargeSubscriptionJob")
    failed = create_failed_job(class_name: "Billing::ChargeSubscriptionJob")
    add_to_batch(batch, ready, pending: true)
    add_to_batch(batch, failed)

    get_fd "/flightdeck/batches/#{batch.id}"

    assert_response :success
    assert_select ".fd-jd-head h2", text: "Nightly billing sweep"
    assert_includes response.body, "NotifyBillingFinishedJob"
    assert_includes response.body, "user_id"
    assert_equal [ ready.id, failed.id ].sort, job_ids_in_response.sort
    assert_select "a[href=?]", "/flightdeck/jobs/#{ready.id}"
  end

  test "a missing batch redirects to the list" do
    get_fd "/flightdeck/batches/999999"

    assert_redirected_to "/flightdeck/batches"
  end

  test "an unknown state redirects to the default list" do
    get_fd "/flightdeck/batches?state=nonsense"

    assert_redirected_to "/flightdeck/batches"
  end

  test "a job that belongs to a batch links back from the job page" do
    batch = create_batch(description: "Nightly billing sweep", total_jobs: 1)
    job = create_ready_job(class_name: "Billing::ChargeSubscriptionJob")
    add_to_batch(batch, job, pending: true)

    get_fd "/flightdeck/jobs/#{job.id}"

    assert_response :success
    assert_select ".fd-part-of a[href=?]", "/flightdeck/batches/#{batch.id}", text: "Nightly billing sweep"
    assert_includes response.body, "pending"
  end

  test "a job with no batch does not render the part-of card" do
    job = create_ready_job

    get_fd "/flightdeck/jobs/#{job.id}"

    assert_response :success
    assert_select ".fd-part-of", count: 0
  end

  private
    def batch_ids_in_response
      response.body.scan(/id="fd-batch-(\d+)"/).flatten.map(&:to_i)
    end
end
