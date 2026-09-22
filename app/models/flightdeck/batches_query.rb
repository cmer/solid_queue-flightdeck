# frozen_string_literal: true

module Flightdeck
  # Feature-detect per request, never at boot — not Batch.migrated?, which memoizes.
  class BatchesQuery
    STATES = %i[all unfinished completed failed].freeze
    PAYLOAD_COLUMNS = %w[on_finish on_success on_failure metadata].freeze

    class InvalidState < ArgumentError; end

    attr_reader :state, :before_id, :limit, :count_cap

    def self.available?
      return false unless defined?(::SolidQueue::Batch)

      ::SolidQueue::Batch.table_exists? &&
        ::SolidQueue::BatchExecution.table_exists? &&
        ::SolidQueue::Job.column_names.include?("batch_id")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    def self.state_counts
      STATES.index_with do |state|
        query = new(state: state)
        { count: query.count, capped: query.count_capped? }
      end
    end

    # Stored columns once finished; two grouped counts while running.
    def self.progress_for(batches)
      batches = Array(batches)
      result = {}

      finished, unfinished = batches.partition { |batch| batch.finished_at.present? }

      finished.each do |batch|
        result[batch.id] = {
          pending_jobs: 0,
          completed_jobs: batch[:completed_jobs].to_i,
          failed_jobs: batch[:failed_jobs].to_i
        }
      end

      return result if unfinished.empty?

      ids = unfinished.map(&:id)
      pending = SolidQueue::BatchExecution.where(batch_id: ids).group(:batch_id).count
      failed = SolidQueue::Job.where(batch_id: ids).joins(:failed_execution).group(:batch_id).count

      unfinished.each do |batch|
        pending_jobs = pending[batch.id].to_i
        failed_jobs = failed[batch.id].to_i
        completed_jobs = [ batch.total_jobs - pending_jobs - failed_jobs, 0 ].max
        result[batch.id] = { pending_jobs: pending_jobs, completed_jobs: completed_jobs, failed_jobs: failed_jobs }
      end

      result
    end

    def initialize(state: :all, before_id: nil, limit: nil, count_cap: nil)
      @state = normalize_state(state)
      @before_id = before_id.presence && Integer(before_id, exception: false)
      @limit = (limit || Flightdeck.config.per_page).to_i.clamp(1, 200)
      @count_cap = (count_cap || Flightdeck.config.count_cap).to_i
    end

    def rows
      @rows ||= build_rows
    end

    def next_cursor
      rows
      @next_cursor
    end

    def next_page? = next_cursor.present?

    def count
      @count ||= Flightdeck::Cache.fetch("count", "batches", state, count_cap,
                                         expires_in: Flightdeck.config.poll_interval) do
        filtered_relation.limit(count_cap).count
      end
    end

    def count_capped? = count >= count_cap

    def filtered_relation
      @filtered_relation ||= apply_filters(model.all)
    end

    def model = SolidQueue::Batch

    private
      def normalize_state(value)
        state = value.presence&.to_sym || :all
        raise InvalidState, "unknown batch state #{value.inspect}" unless STATES.include?(state)

        state
      end

      def build_rows
        page = paginated_records
        @next_cursor = page.size > limit ? page[limit - 1].id : nil
        page = page.first(limit)

        return [] if page.empty?

        progress = self.class.progress_for(page)
        page.map { |batch| BatchRow.new(batch: batch, **progress.fetch(batch.id)) }
      end

      def paginated_records
        relation = filtered_relation
          .reorder(model.arel_table[:id].desc)
          .limit(limit + 1)

        relation = relation.where(model.arel_table[:id].lt(before_id)) if before_id
        relation.select(driving_columns).to_a
      end

      def driving_columns
        (model.column_names - PAYLOAD_COLUMNS).map { |name| model.arel_table[name] }
      end

      def apply_filters(relation)
        case state
        when :unfinished then relation.unfinished
        when :completed then relation.succeeded
        when :failed then relation.failed
        else relation
        end
      end
  end
end
