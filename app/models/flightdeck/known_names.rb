# frozen_string_literal: true

module Flightdeck
  # The distinct queue and job class names Solid Queue has seen, used to turn a
  # search fragment into an exact list of names.
  #
  # `LIKE '%frag%'` can't use an index, so every list, tab count and bulk
  # action would scan the jobs table. Matching here, in Ruby, leaves SQL an
  # indexed `IN (...)` and folds case the same on every adapter.
  #
  # Memoized per process rather than in Rails.cache, so a page's list and seven
  # tab counts cost a couple of DISTINCTs per poll interval whatever the host's
  # cache store. Freshness:
  #   * entries live one poll interval;
  #   * a fragment matching nothing re-reads first (at most every MISS_REFRESH);
  #   * `fresh { }` ignores entries read before it began.
  module KnownNames
    MISS_REFRESH = 1.0 # seconds
    FRESH_KEY = :flightdeck_known_names_fresh_after

    # `fresh` compares `sequence` (equal timestamps can't fool it), the TTL runs
    # from `started_at`, and MISS_REFRESH from `finished_at`, so a slow read
    # isn't due again the moment it lands.
    Entry = Struct.new(:names, :sequence, :started_at, :finished_at)

    COLUMNS = %i[queue_name class_name].freeze

    @memo = {}
    @sequence = 0
    @lock = Mutex.new
    # Held across a read, so concurrent threads share one DISTINCT.
    @read_locks = COLUMNS.index_with { Mutex.new }

    class << self
      def matching_queues(fragment) = matching(:queue_name, fragment)
      def matching_classes(fragment) = matching(:class_name, fragment)

      def fresh
        previous = Thread.current[FRESH_KEY]
        Thread.current[FRESH_KEY] ||= @lock.synchronize { @sequence }
        yield
      ensure
        Thread.current[FRESH_KEY] = previous
      end

      def reset!
        @lock.synchronize { @memo.clear }
      end

      # Public so tests can pin it.
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      private
        # Case-insensitive substring match.
        def matching(column, fragment)
          needle = fragment.to_s.downcase
          entry = current(column)
          found = select(entry.names, needle)
          return found if found.any? || cooling_down?(entry)

          # The name may be newer than the entry.
          select(refresh(column) { |latest| cooling_down?(latest) }.names, needle)
        end

        def select(names, needle)
          names.select { |name| name.downcase.include?(needle) }
        end

        def current(column)
          entry = stored(column)
          valid?(entry) ? entry : refresh(column) { |latest| valid?(latest) }
        end

        def valid?(entry)
          return false unless entry

          fresh_after = Thread.current[FRESH_KEY]
          return entry.sequence > fresh_after if fresh_after

          now - entry.started_at < ttl
        end

        def cooling_down?(entry) = now - entry.finished_at < MISS_REFRESH

        def stored(column) = @lock.synchronize { @memo[column] }

        # A thread that waited takes the entry the one ahead of it read, if
        # `good_enough`. Connection before lock: the reverse order deadlocks
        # once the pool is exhausted.
        def refresh(column, &good_enough)
          SolidQueue::Job.connection_pool.with_connection do
            @read_locks.fetch(column).synchronize do
              latest = stored(column)
              return latest if latest && good_enough.call(latest)

              read(column)
            end
          end
        end

        def read(column)
          sequence = @lock.synchronize { @sequence += 1 }
          started_at = now
          # Uncached, or a stale cached result would pass as a fresh read.
          names = SolidQueue::Job.uncached { SolidQueue::Job.distinct.pluck(column) }.compact.sort
          entry = Entry.new(names, sequence, started_at, now)

          @lock.synchronize do
            # Never let an older read replace a newer one.
            existing = @memo[column]
            @memo[column] = entry if existing.nil? || existing.sequence < entry.sequence
          end
          entry
        end

        def ttl = [ Flightdeck.config.poll_interval.to_f, 1.0 ].max
    end
  end
end
