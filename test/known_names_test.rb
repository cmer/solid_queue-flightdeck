# frozen_string_literal: true

require "test_helper"

class KnownNamesTest < ActiveSupport::TestCase
  test "a filtered page reads each column's names once, even without a cache store" do
    create_failed_job(class_name: "Billing::ChargeJob", queue_name: "critical")

    reads = with_cache_store(nil) do
      count_distinct_reads do
        Flightdeck::JobsQuery.new(state: :failed, q: "charge", queue_name: "crit").rows
        Flightdeck::JobsQuery.state_counts(q: "charge", queue_name: "crit")
      end
    end

    assert_equal 2, reads
  end

  test "names are re-read once the poll interval passes" do
    create_ready_job(class_name: "OldJob")

    with_known_names_clock do |clock|
      assert_equal [ "OldJob" ], matching_classes("job")
      create_ready_job(class_name: "NewJob")

      clock.advance(0.5)
      assert_equal [ "OldJob" ], matching_classes("job"), "still inside the interval"

      clock.advance(Flightdeck.config.poll_interval)
      assert_equal %w[NewJob OldJob], matching_classes("job")
    end
  end

  test "a fragment that matches nothing re-reads before answering no matches" do
    create_ready_job(class_name: "OldJob")

    with_known_names_clock do |clock|
      matching_classes("old")
      create_ready_job(class_name: "DeployedJustNowJob")

      clock.advance(Flightdeck::KnownNames::MISS_REFRESH)
      assert_equal [ "DeployedJustNowJob" ], matching_classes("deployed")
    end
  end

  test "repeated no-match searches re-read at most once per MISS_REFRESH" do
    create_ready_job(class_name: "OldJob")

    with_known_names_clock do |clock|
      reads = count_distinct_reads do
        matching_classes("nope")
        clock.advance(Flightdeck::KnownNames::MISS_REFRESH / 4)
        3.times { matching_classes("nope") }
      end

      assert_equal 1, reads
    end
  end

  # The cooldown runs from when a read returned, or a slow read is due again at once.
  test "a slow read does not immediately trigger a second read" do
    create_ready_job(class_name: "OldJob")

    with_known_names_clock do |clock|
      reads = count_distinct_reads(on_read: -> { clock.advance(Flightdeck::KnownNames::MISS_REFRESH * 1.5) }) do
        assert_empty matching_classes("nope")
        assert_empty matching_classes("nope")
      end

      assert_equal 1, reads
    end
  end

  # The first read is held open until the other threads are parked on the lock.
  test "threads that find the names expired together share one read" do
    create_ready_job(class_name: "OldJob")

    with_known_names_clock do |clock|
      matching_classes("old")
      clock.advance(Flightdeck.config.poll_interval + 1)

      waiters = []
      reading = Queue.new
      hold_first_read = lambda do
        reading << true
        wait_until { waiters.size == 7 && waiters.all? { |thread| thread.status == "sleep" } }
      end

      results = nil
      reads = count_distinct_reads(on_read: hold_first_read) do
        first = Thread.new { matching_classes("old") }
        wait_until { !reading.empty? || !first.alive? }
        7.times { waiters << Thread.new { matching_classes("old") } }
        results = [ first, *waiters ].map { |thread| thread.join(10)&.value }
      ensure
        # Join after kill, so teardown never reclaims the connection mid-unwind.
        threads = [ first, *waiters ].compact
        threads.each(&:kill)
        threads.each { |thread| thread.join(5) }
      end

      assert_equal 1, reads
      assert_equal [ [ "OldJob" ] ] * 8, results
    end
  end

  test "a read inside fresh is never served from the query cache" do
    create_ready_job(class_name: "OldJob")

    reads = SolidQueue::Job.cache do
      count_distinct_reads do
        matching_classes("job")
        Flightdeck::KnownNames.fresh { matching_classes("job") }
      end
    end

    assert_equal 2, reads, "the second DISTINCT must reach the database, not the query cache"
  end

  test "fresh ignores names read before the block began" do
    create_ready_job(class_name: "OldJob")
    matching_classes("job")
    create_ready_job(class_name: "NewJob")

    Flightdeck::KnownNames.fresh do
      assert_equal %w[NewJob OldJob], matching_classes("job")
    end
  end

  test "fresh restores the outer state, also when the block raises" do
    assert_raises(RuntimeError) { Flightdeck::KnownNames.fresh { raise "boom" } }
    assert_nil Thread.current[Flightdeck::KnownNames::FRESH_KEY]

    Flightdeck::KnownNames.fresh do
      outer = Thread.current[Flightdeck::KnownNames::FRESH_KEY]
      Flightdeck::KnownNames.fresh { assert_equal outer, Thread.current[Flightdeck::KnownNames::FRESH_KEY] }
      assert_equal outer, Thread.current[Flightdeck::KnownNames::FRESH_KEY]
    end
    assert_nil Thread.current[Flightdeck::KnownNames::FRESH_KEY]
  end

  private
    def matching_classes(fragment) = Flightdeck::KnownNames.matching_classes(fragment)

    # Real clock (KnownNames' may be pinned); gives up rather than hang.
    def wait_until(seconds: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    def count_distinct_reads(on_read: nil)
      reads = 0
      lock = Mutex.new
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next unless payload[:sql].match?(/SELECT DISTINCT/i) && !payload[:cached]

        lock.synchronize { reads += 1 }
        on_read&.call
      end
      yield
      reads
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def with_cache_store(store)
      previous = Rails.cache
      Rails.cache = store
      yield
    ensure
      Rails.cache = previous
    end
end
