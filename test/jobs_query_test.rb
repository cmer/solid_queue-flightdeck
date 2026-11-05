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

  test "filters compose on states whose execution table has no queue column" do
    a = create_failed_job(class_name: "AlphaJob", queue_name: "critical")
    create_failed_job(class_name: "AlphaJob", queue_name: "low")
    create_failed_job(class_name: "BetaJob", queue_name: "critical")

    query = Flightdeck::JobsQuery.new(state: :failed, class_name: "AlphaJob", queue_name: "critical")

    assert_equal [ a.id ], query.rows.map(&:id)
    assert_equal 1, query.count
  end

  test "search is a case-insensitive substring match on the job class" do
    match = create_ready_job(class_name: "Billing::ChargeJob")
    create_ready_job(class_name: "WebhookJob")

    assert_equal [ match.id ], Flightdeck::JobsQuery.new(state: :ready, q: "Billing").rows.map(&:id)
    assert_equal [ match.id ], Flightdeck::JobsQuery.new(state: :ready, q: "chargejob").rows.map(&:id)
    assert_empty Flightdeck::JobsQuery.new(state: :ready, q: "Refund").rows
  end

  test "queue filter is a case-insensitive substring match" do
    a = create_failed_job(queue_name: "within_5_minutes")
    b = create_ready_job(queue_name: "within_1_minute")
    create_ready_job(queue_name: "default")

    assert_equal [ a.id ], Flightdeck::JobsQuery.new(state: :failed, queue_name: "5_MIN").rows.map(&:id)
    assert_equal [ b.id ], Flightdeck::JobsQuery.new(state: :ready, queue_name: "within").rows.map(&:id)
  end

  test "search treats wildcard characters literally" do
    create_ready_job(class_name: "AlphaJob", queue_name: "low")
    create_ready_job(class_name: "Under_scoreJob", queue_name: "a_b")

    assert_empty Flightdeck::JobsQuery.new(state: :ready, q: "%").rows
    assert_empty Flightdeck::JobsQuery.new(state: :ready, q: "_lphaJob").rows
    assert_equal 1, Flightdeck::JobsQuery.new(state: :ready, q: "r_s").count
    assert_empty Flightdeck::JobsQuery.new(state: :ready, queue_name: "l_w").rows
    assert_empty Flightdeck::JobsQuery.new(state: :ready, queue_name: "\\").rows
  end

  test "search folds case beyond ASCII" do
    job = create_ready_job(class_name: "ÉmailJob", queue_name: "Ünicode")

    assert_equal [ job.id ], Flightdeck::JobsQuery.new(state: :ready, q: "émail").rows.map(&:id)
    assert_equal [ job.id ], Flightdeck::JobsQuery.new(state: :ready, queue_name: "ünI").rows.map(&:id)
  end

  test "fragments resolve to an exact IN list, never a LIKE scan" do
    create_ready_job(class_name: "Billing::ChargeJob", queue_name: "within_5_minutes")
    create_ready_job(class_name: "WebhookJob", queue_name: "default")

    sql = capture_sql do
      query = Flightdeck::JobsQuery.new(state: :ready, q: "charge", queue_name: "5_min")
      query.rows
      query.count
    end

    filtered = sql.grep(/solid_queue_ready_executions/)
    assert filtered.any?
    filtered.each { |statement| refute_match(/\bLIKE\b/i, statement) }
    assert filtered.any? { |statement| statement.include?("Billing::ChargeJob") }
  end

  test "a fragment matching no known name returns nothing in every state" do
    create_failed_job(class_name: "AlphaJob", queue_name: "critical")

    Flightdeck::JobsQuery::STATES.each do |state|
      assert_equal 0, Flightdeck::JobsQuery.new(state: state, q: "Nope").count, state
      assert_equal 0, Flightdeck::JobsQuery.new(state: state, queue_name: "nope").count, state
    end
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

    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA"
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
