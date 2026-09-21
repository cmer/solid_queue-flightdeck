# frozen_string_literal: true

require "test_helper"

class Flightdeck::JobsQueryTest < ActiveSupport::TestCase
  test "each state drives from the table that makes the state true" do
    scenario = create_full_scenario

    assert_equal [ scenario[:ready].id ], ids_for(:ready)
    assert_equal [ scenario[:scheduled].id ], ids_for(:scheduled)
    assert_equal [ scenario[:in_progress].id ], ids_for(:in_progress)
    assert_equal [ scenario[:blocked].id ], ids_for(:blocked)
    assert_equal [ scenario[:failed].id ], ids_for(:failed)
    assert_equal [ scenario[:finished].id ], ids_for(:finished)
    assert_equal scenario.values.map(&:id).sort, ids_for(:all).sort
  end

  test "the all state annotates each row with the state its execution row implies" do
    scenario = create_full_scenario

    states = Flightdeck::JobsQuery.new(state: :all).rows.to_h { |row| [ row.id, row.state ] }

    scenario.each do |expected_state, job|
      assert_equal expected_state, states[job.id], "job #{job.id} should be #{expected_state}"
    end
  end

  test "rejects an unknown state rather than silently listing everything" do
    assert_raises(Flightdeck::JobsQuery::InvalidState) { Flightdeck::JobsQuery.new(state: :nope) }
  end

  test "filters by class name and queue name, and composes them" do
    a = create_ready_job(class_name: "AlphaJob", queue_name: "critical")
    create_ready_job(class_name: "AlphaJob", queue_name: "low")
    create_ready_job(class_name: "BetaJob", queue_name: "critical")

    assert_equal 2, Flightdeck::JobsQuery.new(state: :ready, class_name: "AlphaJob").count
    assert_equal 2, Flightdeck::JobsQuery.new(state: :ready, queue_name: "critical").count

    composed = Flightdeck::JobsQuery.new(state: :ready, class_name: "AlphaJob", queue_name: "critical")
    assert_equal [ a.id ], composed.rows.map(&:id)
  end

  test "filters by batch membership on ready and failed states" do
    batch = create_batch(total_jobs: 2)
    ready = create_ready_job(class_name: "AlphaJob")
    failed = create_failed_job(class_name: "AlphaJob")
    add_to_batch(batch, ready, pending: true)
    add_to_batch(batch, failed)
    create_ready_job(class_name: "BetaJob")
    create_failed_job(class_name: "BetaJob")

    ready_query = Flightdeck::JobsQuery.new(state: :ready, batch_id: batch.id)
    failed_query = Flightdeck::JobsQuery.new(state: :failed, batch_id: batch.id)

    assert_equal [ ready.id ], ready_query.rows.map(&:id)
    assert_equal 1, ready_query.count
    assert_equal [ failed.id ], failed_query.rows.map(&:id)
  end

  test "filters compose on states whose execution table has no queue column" do
    a = create_failed_job(class_name: "AlphaJob", queue_name: "critical")
    create_failed_job(class_name: "AlphaJob", queue_name: "low")
    create_failed_job(class_name: "BetaJob", queue_name: "critical")

    query = Flightdeck::JobsQuery.new(state: :failed, class_name: "AlphaJob", queue_name: "critical")

    assert_equal [ a.id ], query.rows.map(&:id)
    assert_equal 1, query.count
  end

  test "search is a prefix match on the job class" do
    match = create_ready_job(class_name: "Billing::ChargeJob")
    create_ready_job(class_name: "WebhookJob")

    assert_equal [ match.id ], Flightdeck::JobsQuery.new(state: :ready, q: "Billing").rows.map(&:id)
    assert_empty Flightdeck::JobsQuery.new(state: :ready, q: "ChargeJob").rows
  end

  test "search escapes LIKE wildcards instead of treating them as a pattern" do
    create_ready_job(class_name: "AlphaJob")

    assert_empty Flightdeck::JobsQuery.new(state: :ready, q: "%").rows
    assert_empty Flightdeck::JobsQuery.new(state: :ready, q: "_lphaJob").rows
  end

  test "keyset pagination walks pages without overlap or gaps" do
    jobs = 7.times.map { create_ready_job }
    expected = jobs.map(&:id).sort.reverse

    seen = []
    cursor = nil
    3.times do
      query = Flightdeck::JobsQuery.new(state: :ready, limit: 3, before_id: cursor)
      seen.concat(query.rows.map(&:id))
      cursor = query.next_cursor
    end

    assert_equal expected, seen
    assert_equal seen.uniq, seen, "pages overlapped"
    assert_nil cursor, "there should be no page after the last one"
  end

  test "next_cursor is nil on the final page" do
    2.times { create_ready_job }

    assert_nil Flightdeck::JobsQuery.new(state: :ready, limit: 5).next_cursor
    assert_not_nil Flightdeck::JobsQuery.new(state: :ready, limit: 1).next_cursor
  end

  test "counts are capped and report themselves as capped" do
    5.times { create_ready_job }

    query = Flightdeck::JobsQuery.new(state: :ready, count_cap: 3)

    assert_equal 3, query.count
    assert query.count_capped?

    uncapped = Flightdeck::JobsQuery.new(state: :ready, count_cap: 100)
    assert_equal 5, uncapped.count
    refute uncapped.count_capped?
  end

  test "list queries never select the arguments or error columns" do
    create_failed_job
    create_ready_job

    statements = capture_sql do
      Flightdeck::JobsQuery.new(state: :failed).rows
      Flightdeck::JobsQuery.new(state: :all).rows
    end

    driving = statements.reject { |sql| sql.include?("SUBSTR") }

    assert driving.any?, "expected some driving queries"
    driving.each do |sql|
      refute_match(/SELECT[^;]*\barguments\b/i, sql, "a list query selected arguments:\n#{sql}")
      refute_match(/SELECT[^;]*\berror\b/i, sql, "a list query selected error:\n#{sql}")
    end
  end

  test "argument previews are fetched truncated, for the current page only" do
    create_ready_job(arguments: { "arguments" => [ "x" * 5_000 ] })

    row = Flightdeck::JobsQuery.new(state: :ready).rows.first

    assert row.args_preview.bytesize <= Flightdeck::JobsQuery::ARGUMENTS_PREVIEW_BYTES
    assert_includes row.args_preview, "xxxx"
  end

  test "failed rows carry a parsed error summary" do
    create_failed_job(exception_class: "Net::ReadTimeout", message: "boom")

    row = Flightdeck::JobsQuery.new(state: :failed).rows.first

    assert_equal "Net::ReadTimeout", row.error_summary.exception_class
    assert_equal "boom", row.error_summary.message
  end

  test "an error summary survives JSON truncated mid-backtrace" do
    create_failed_job(exception_class: "Elastic::TransportError",
                      message: "circuit breaking",
                      backtrace: [ "frame #{"y" * 4_000}" ])

    row = Flightdeck::JobsQuery.new(state: :failed).rows.first

    assert_equal "Elastic::TransportError", row.error_summary.exception_class
    assert_equal "circuit breaking", row.error_summary.message
  end

  test "in-progress rows resolve the process that claimed them" do
    process = create_process(name: "worker-42", pid: 99)
    create_claimed_job(process: process)

    row = Flightdeck::JobsQuery.new(state: :in_progress).rows.first

    assert_equal "worker-42", row.process.name
    assert_equal 99, row.process.pid
  end

  test "state_counts reports every tab" do
    create_full_scenario

    counts = Flightdeck::JobsQuery.state_counts

    assert_equal 6, counts[:all][:count]
    assert_equal 1, counts[:failed][:count]
    assert_equal 1, counts[:finished][:count]
    refute counts[:all][:capped]
  end

  private
    def ids_for(state)
      Flightdeck::JobsQuery.new(state: state).rows.map(&:id)
    end
end
