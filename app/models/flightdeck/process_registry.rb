# frozen_string_literal: true

module Flightdeck
  # The Solid Queue fleet: every registered process, grouped supervisor →
  # children, with heartbeat freshness and claimed counts.
  #
  # Two queries total, regardless of fleet size.
  class ProcessRegistry
    # Freshness is measured against Solid Queue's own liveness threshold rather
    # than a number of our own, so what Flightdeck calls dead is exactly what
    # the pruner will collect.
    FRESH_FRACTION = 0.2

    Node = Struct.new(:process, :claimed_count, :children, keyword_init: true) do
      def id = process.id
      def kind = process.kind
      def name = process.name
      def hostname = process.hostname
      def pid = process.pid
      def last_heartbeat_at = process.last_heartbeat_at
      def supervisor? = kind == "Supervisor"
      def claims_executions? = kind == "Worker"

      def heartbeat_age
        Time.current - last_heartbeat_at
      end

      def freshness
        threshold = SolidQueue.process_alive_threshold
        age = heartbeat_age

        if age >= threshold then :dead
        elsif age >= threshold * FRESH_FRACTION then :stale
        else :fresh
        end
      end

      def dead? = freshness == :dead
      def prunable? = dead?

      def metadata
        process.metadata.presence || {}
      end

      # Human summary of what this process was configured to do. Keys differ per
      # process kind, so known ones are formatted and anything else is shown
      # verbatim rather than dropped.
      def config_summary
        parts = []
        data = metadata.symbolize_keys

        parts << "queues: #{data[:queues]}" if data[:queues].present?
        parts << "#{data[:thread_pool_size]} threads" if data[:thread_pool_size].present?
        parts << "batch #{data[:batch_size]}" if data[:batch_size].present?
        parts << "every #{data[:polling_interval]}s" if data[:polling_interval].present?
        parts << "#{Array(data[:recurring_schedule]).size} recurring tasks" if data[:recurring_schedule].present?

        known = %i[queues thread_pool_size batch_size polling_interval recurring_schedule
                   concurrency_maintenance_interval]
        data.except(*known).each { |key, value| parts << "#{key}: #{value}" }

        parts.join(" · ")
      end
    end

    def nodes
      @nodes ||= build_nodes
    end

    # Supervisors with their children nested; anything unsupervised (or whose
    # supervisor row has gone) is listed flat so it can never be hidden.
    def tree
      @tree ||= begin
        by_supervisor = nodes.group_by { |node| node.process.supervisor_id }
        known_ids = nodes.map(&:id).to_set

        roots = nodes.select { |node| node.process.supervisor_id.nil? || !known_ids.include?(node.process.supervisor_id) }
        roots.each { |root| root.children = by_supervisor.fetch(root.id, []) }
        roots
      end
    end

    def dead = nodes.select(&:dead?)
    def any_dead? = dead.any?
    def dead_claimed_count = dead.sum(&:claimed_count)
    def total = nodes.size

    def find(id)
      nodes.find { |node| node.id == id.to_i }
    end

    private
      def build_nodes
        processes = SolidQueue::Process.order(:kind, :id).to_a
        claimed = SolidQueue::ClaimedExecution.group(:process_id).count

        processes.map do |process|
          Node.new(process: process, claimed_count: claimed.fetch(process.id, 0), children: [])
        end
      end
  end
end
