# frozen_string_literal: true

module Flightdeck
  # Everything the Overview page shows, assembled from the same query objects
  # the rest of the dashboard uses.
  class Overview
    WINDOW = 24.hours
    RECENT_FAILURES = 5
    TOP_QUEUES = 6

    # `value` is always display-ready text — a delimited count, a duration, or
    # "—" — so the view prints it without asking what kind of number it was.
    # trend is :up / :down / :flat and says which way the number moved, while
    # `good` says whether that movement is a good thing — more throughput is
    # good, more failures are not.
    Tile = Struct.new(:label, :value, :unit, :detail, :trend, :good, keyword_init: true)

    attr_reader :now

    def initialize(now: Time.current)
      @now = now
    end

    def tiles
      [ processed_tile, failed_tile, ready_tile, blocked_tile, scheduled_tile, in_progress_tile,
        oldest_ready_tile ]
    end

    def series(window: Metrics::Series::DEFAULT_WINDOW)
      @series ||= {}
      @series[window.to_s] ||= Metrics::Series.new(window: window, now: now)
    end

    def queues
      @queues ||= QueueStats.new.rows.sort_by { |row| -row.depth }.first(TOP_QUEUES)
    end

    def max_queue_depth
      @max_queue_depth ||= [ queues.map(&:depth).max.to_i, 1 ].max
    end

    def sparklines
      @sparklines ||= Metrics::Series.queue_sparklines(now: now)
    end

    def sparkline_for(queue_name)
      Metrics::Sparkline.new(sparklines[queue_name] || [])
    end

    def recent_failures
      @recent_failures ||= JobsQuery.new(state: :failed, limit: RECENT_FAILURES).rows
    end

    def failed_count
      @failed_count ||= JobsQuery.new(state: :failed).count
    end

    def registry
      @registry ||= ProcessRegistry.new
    end

    # --- counts ---------------------------------------------------------------

    def processed_24h
      @processed_24h ||= counted("processed", WINDOW) { SolidQueue::Job.where(finished_at: (now - WINDOW)..now) }
    end

    def processed_prior_24h
      @processed_prior_24h ||= counted("processed_prior", WINDOW) do
        SolidQueue::Job.where(finished_at: (now - (WINDOW * 2))...(now - WINDOW))
      end
    end

    def failed_24h
      @failed_24h ||= counted("failed", WINDOW) { SolidQueue::FailedExecution.where(created_at: (now - WINDOW)..now) }
    end

    def ready_now = @ready_now ||= counted("ready") { SolidQueue::ReadyExecution.all }
    def blocked = @blocked ||= counted("blocked") { SolidQueue::BlockedExecution.all }
    def scheduled = @scheduled ||= counted("scheduled") { SolidQueue::ScheduledExecution.all }
    def in_progress = @in_progress ||= counted("in_progress") { SolidQueue::ClaimedExecution.all }

    def next_scheduled_at
      @next_scheduled_at ||= Cache.fetch("overview", "next_scheduled", expires_in: count_ttl) do
        SolidQueue::ScheduledExecution.minimum(:scheduled_at)
      end
    end

    def oldest_ready_at
      @oldest_ready_at ||= Cache.fetch("overview", "oldest_ready", expires_in: count_ttl) do
        SolidQueue::ReadyExecution.minimum(:created_at)
      end
    end

    def oldest_ready_age
      oldest_ready_at && now - oldest_ready_at
    end

    # Total worker capacity, summed from each worker's registered thread pool
    # size. Returns nil when no worker reported one, so the tile can omit the
    # denominator rather than divide by a number it invented.
    #
    # A worker that has stopped sending heartbeats is not capacity, whatever its
    # metadata still says, so dead workers are excluded — otherwise utilization
    # reads low precisely when the fleet is in trouble.
    def slots
      @slots ||= begin
        sizes = registry.nodes.filter_map do |node|
          next unless node.claims_executions? && !node.dead?

          Integer(node.metadata.symbolize_keys[:thread_pool_size], exception: false)
        end
        sizes.any? ? sizes.sum : nil
      end
    end

    def utilization
      return nil if slots.nil? || slots.zero?

      (in_progress.to_f / slots * 100).round
    end

    def failure_rate
      total = processed_24h + failed_24h
      return nil if total.zero?

      (failed_24h.to_f / total * 100).round(1)
    end

    def processed_delta
      return nil if processed_prior_24h.zero?

      ((processed_24h - processed_prior_24h).to_f / processed_prior_24h * 100).round(1)
    end

    private
      def count_ttl = Flightdeck.config.poll_interval

      def counted(name, window = nil, &relation)
        Cache.fetch("overview", name, window&.to_i, expires_in: count_ttl) do
          relation.call.limit(Flightdeck.config.count_cap).count
        end
      end

      def processed_tile
        delta = processed_delta

        Tile.new(
          label: "Processed · 24h",
          value: number(processed_24h),
          detail: delta.nil? ? "no prior window to compare" : "#{delta.abs}% vs prior 24h",
          trend: trend_for(delta),
          good: delta.nil? || delta >= 0
        )
      end

      def failed_tile
        rate = failure_rate

        Tile.new(
          label: "Failed · 24h",
          value: number(failed_24h),
          detail: rate.nil? ? "nothing finished yet" : "#{rate}% failure rate",
          trend: failed_24h.positive? ? :up : :flat,
          good: failed_24h.zero?
        )
      end

      def ready_tile
        Tile.new(label: "Ready now", value: number(ready_now), detail: "waiting to be claimed", trend: :flat, good: true)
      end

      def blocked_tile
        Tile.new(
          label: "Blocked",
          value: number(blocked),
          detail: blocked.zero? ? "nothing blocked" : "held by concurrency limits",
          trend: :flat,
          good: true
        )
      end

      def scheduled_tile
        detail =
          if next_scheduled_at.nil? then "nothing scheduled"
          elsif next_scheduled_at <= now then "due now"
          else "next due in #{Duration.humanize(next_scheduled_at - now)}"
          end

        Tile.new(label: "Scheduled", value: number(scheduled), detail: detail, trend: :flat, good: true)
      end

      def in_progress_tile
        Tile.new(
          label: "In progress",
          value: number(in_progress),
          unit: slots ? "/ #{number(slots)} slots" : nil,
          detail: utilization ? "#{utilization}% utilization" : "no worker capacity reported",
          trend: :flat,
          good: true
        )
      end

      def oldest_ready_tile
        Tile.new(
          label: "Oldest ready",
          value: oldest_ready_age ? Duration.humanize(oldest_ready_age) : "—",
          detail: oldest_ready_age ? "longest a job has waited" : "nothing waiting",
          trend: :flat,
          good: true
        )
      end

      def number(value) = ActiveSupport::NumberHelper.number_to_delimited(value)

      def trend_for(delta)
        return :flat if delta.nil? || delta.abs < 0.05

        delta.positive? ? :up : :down
      end
  end
end
