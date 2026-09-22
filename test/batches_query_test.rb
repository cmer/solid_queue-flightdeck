# frozen_string_literal: true

require "test_helper"

class Flightdeck::BatchesQueryTest < ActiveSupport::TestCase
  test "available? is true once the batches schema is present" do
    assert Flightdeck::BatchesQuery.available?
  end

  test "available? is false when jobs lack a batch_id column" do
    original = SolidQueue::Job.method(:column_names)
    SolidQueue::Job.define_singleton_method(:column_names) { original.call - [ "batch_id" ] }

    refute Flightdeck::BatchesQuery.available?
  ensure
    SolidQueue::Job.singleton_class.remove_method(:column_names)
  end

  test "rejects an unknown state" do
    assert_raises(Flightdeck::BatchesQuery::InvalidState) { Flightdeck::BatchesQuery.new(state: :nope) }
  end

  test "each tab lists the batches in that status" do
    running = create_batch(description: "Running", total_jobs: 1, enqueued_at: Time.current)
    add_to_batch(running, create_ready_job, pending: true)
    completed = create_finished_batch(description: "Done")
    failed = create_failed_batch(description: "Broken")

    assert_equal [ running.id ], ids_for(:unfinished)
    assert_equal [ completed.id ], ids_for(:completed)
    assert_equal [ failed.id ], ids_for(:failed)
    assert_equal [ running.id, completed.id, failed.id ].sort, ids_for(:all).sort
  end

  test "unfinished progress is hydrated from grouped counts, not the stale columns" do
    batch = create_batch(description: "Sweep", total_jobs: 5, completed_jobs: 0, failed_jobs: 0)
    3.times { add_to_batch(batch, create_ready_job(class_name: "SweepJob"), pending: true) }
    add_to_batch(batch, create_finished_job(class_name: "SweepJob"))
    add_to_batch(batch, create_failed_job(class_name: "SweepJob"))

    row = Flightdeck::BatchesQuery.new.rows.first

    assert_equal 3, row.pending_jobs
    assert_equal 1, row.failed_jobs
    assert_equal 1, row.completed_jobs
    assert_equal :enqueued, row.status
  end

  test "finished batches use the stored counters" do
    create_finished_batch(description: "Done", job_count: 3)

    row = Flightdeck::BatchesQuery.new(state: :completed).rows.first

    assert_equal 0, row.pending_jobs
    assert_equal 3, row.completed_jobs
    assert_equal 0, row.failed_jobs
    assert_equal :completed, row.status
  end

  test "keyset pagination walks pages without overlap or gaps" do
    batches = 7.times.map { |i| create_batch(description: "Batch #{i}") }
    expected = batches.map(&:id).sort.reverse

    seen = []
    cursor = nil
    3.times do
      query = Flightdeck::BatchesQuery.new(limit: 3, before_id: cursor)
      seen.concat(query.rows.map(&:id))
      cursor = query.next_cursor
    end

    assert_equal expected, seen
    assert_equal seen.uniq, seen
    assert_nil cursor
  end

  test "counts are capped" do
    5.times { |i| create_batch(description: "B#{i}") }

    query = Flightdeck::BatchesQuery.new(count_cap: 3)

    assert_equal 3, query.count
    assert query.count_capped?
  end

  test "list queries never select callback or metadata columns" do
    create_finished_batch

    statements = capture_sql do
      Flightdeck::BatchesQuery.new.rows
    end

    driving = statements.select { |sql| sql.match?(/FROM ["`]?solid_queue_batches/i) }

    assert driving.any?, "expected a driving query against solid_queue_batches"
    driving.each do |sql|
      refute_match(/SELECT[^;]*\bon_finish\b/i, sql, "a list query selected on_finish:\n#{sql}")
      refute_match(/SELECT[^;]*\bon_success\b/i, sql, "a list query selected on_success:\n#{sql}")
      refute_match(/SELECT[^;]*\bon_failure\b/i, sql, "a list query selected on_failure:\n#{sql}")
      refute_match(/SELECT[^;]*\bmetadata\b/i, sql, "a list query selected metadata:\n#{sql}")
    end
  end

  test "state_counts reports every tab" do
    create_batch(description: "Running", total_jobs: 1)
    create_finished_batch
    create_failed_batch

    counts = Flightdeck::BatchesQuery.state_counts

    assert_equal 3, counts[:all][:count]
    assert_equal 1, counts[:unfinished][:count]
    assert_equal 1, counts[:completed][:count]
    assert_equal 1, counts[:failed][:count]
  end

  private
    def ids_for(state)
      Flightdeck::BatchesQuery.new(state: state).rows.map(&:id)
    end
end
