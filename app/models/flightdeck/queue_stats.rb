# frozen_string_literal: true

module Flightdeck
  # One row per queue, assembled from four grouped queries rather than the
  # per-queue lookups SolidQueue::Queue#size / #latency would do — those are an
  # N+1 as soon as an application has more than a handful of queues.
  #
  # Pausing and resuming still go through SolidQueue::Queue, which owns the
  # semantics; Flightdeck never writes to solid_queue_pauses itself.
  class QueueStats
    RATE_WINDOW = 1.hour

    Row = Struct.new(:name, :depth, :oldest_ready_at, :paused_at, :completed_in_window,
                     keyword_init: true) do
      def paused? = paused_at.present?

      # Latency only means something when something is actually waiting: an
      # empty queue has no oldest job, and reporting "0s" would imply we
      # measured rather than that there was nothing to measure.
      def latency
        return nil if depth.zero? || oldest_ready_at.nil?

        Time.current - oldest_ready_at
      end

      def paused_for
        paused_at && Time.current - paused_at
      end

      def rate_per_hour = completed_in_window
      def idle? = depth.zero? && completed_in_window.zero?
    end

    def rows
      @rows ||= names.sort.map do |name|
        Row.new(
          name: name,
          depth: depths.fetch(name, 0),
          oldest_ready_at: oldest_ready.fetch(name, nil),
          paused_at: pauses.fetch(name, nil),
          completed_in_window: completions.fetch(name, 0)
        )
      end
    end

    def find(name)
      rows.find { |row| row.name == name }
    end

    def any_paused? = rows.any?(&:paused?)

    private
      # A queue is worth showing if Solid Queue knows about it, if something is
      # waiting on it, or if it is paused — a paused queue with nothing in it is
      # exactly the one an operator needs to be reminded of.
      def names
        (queue_names + depths.keys + pauses.keys + completions.keys).compact.uniq
      end

      def queue_names
        SolidQueue::Queue.all.map(&:name)
      end

      def depths
        @depths ||= SolidQueue::ReadyExecution.group(:queue_name).count
      end

      def oldest_ready
        @oldest_ready ||= SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at)
      end

      def pauses
        @pauses ||= SolidQueue::Pause.pluck(:queue_name, :created_at).to_h
      end

      # Bounded by the window rather than by a row cap: a grouped count cannot
      # be capped per group the way a single count can, and an hour of finished
      # jobs is already a bounded, index-backed range scan.
      def completions
        @completions ||= SolidQueue::Job
          .where(finished_at: RATE_WINDOW.ago..)
          .group(:queue_name)
          .count
      end
  end
end
