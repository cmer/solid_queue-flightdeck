# frozen_string_literal: true

module Flightdeck
  # Builds every jobs list in Flightdeck.
  #
  # Rule zero: everything goes through SolidQueue's own models, so multi-database
  # routing comes for free and the host's connection is never touched.
  #
  # Two shapes of query, chosen by state:
  #   * an execution-backed state drives from its own table (that is what makes
  #     the state true) and then loads the matching jobs;
  #   * "all" and "finished" drive from solid_queue_jobs and have their state
  #     annotated afterwards.
  #
  # The `arguments` and `error` columns are never in a list's driving query.
  # Both are fetched afterwards for the current page only, and truncated in SQL
  # so a page of pathological payloads still costs a bounded number of bytes.
  class JobsQuery
    STATES = %i[all ready scheduled in_progress blocked finished failed].freeze

    # Enough that the ActiveJob envelope (job_class, job_id, queue_name…) is
    # comfortably past and the arguments themselves are in the prefix.
    ARGUMENTS_PREVIEW_BYTES = 800
    ERROR_PREVIEW_BYTES = 1_000

    class InvalidState < ArgumentError; end

    attr_reader :state, :class_name, :queue_name, :q, :before_id, :limit, :count_cap

    def initialize(state: :all, class_name: nil, queue_name: nil, q: nil, before_id: nil,
                   limit: nil, count_cap: nil)
      @state = normalize_state(state)
      @class_name = class_name.presence
      @queue_name = queue_name.presence
      @q = q.presence
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

    # Capped so that a jobs table with tens of millions of rows cannot turn a
    # page render into a full scan. Views render `count_capped?` as "500,000+".
    #
    # Cached for one poll interval: the state tabs and the sidebar issue several
    # of these per render, and a count that is at most one poll stale is exactly
    # as fresh as the page it appears on. Mutations wrap themselves in
    # Cache.bypass so an action's own response never shows pre-action numbers.
    def count
      @count ||= Flightdeck::Cache.fetch("count", state, count_cap, cache_filters,
                                         expires_in: Flightdeck.config.poll_interval) do
        filtered_relation.limit(count_cap).count
      end
    end

    def count_capped? = count >= count_cap

    def filters?
      class_name.present? || queue_name.present? || q.present?
    end

    # The filtered relation with no ordering, limit or cursor — what bulk
    # "apply to all matching" re-runs server-side.
    def filtered_relation
      @filtered_relation ||= apply_filters(model.all)
    end

    def model
      @model ||= JobRow.model_for(state) || SolidQueue::Job
    end

    def execution_backed? = model != SolidQueue::Job

    # Counts for the state tabs, each capped independently.
    def self.state_counts(**filters)
      STATES.index_with do |state|
        query = new(**filters.except(:state, :before_id), state: state)
        { count: query.count, capped: query.count_capped? }
      end
    end

    private
      # The columns list queries must never drag along: `arguments` on jobs and
      # `error` on failed_executions can each run to kilobytes per row.
      PAYLOAD_COLUMNS = %w[arguments error].freeze

      # Only the filters change what a count means — the cursor and page size do
      # not, so they are deliberately absent from the key.
      def cache_filters
        { class_name: class_name, queue_name: queue_name, q: q }
      end

      def normalize_state(value)
        state = value.presence&.to_sym || :all
        raise InvalidState, "unknown job state #{value.inspect}" unless STATES.include?(state)

        state
      end

      def build_rows
        page = paginated_records
        @next_cursor = page.size > limit ? page[limit - 1].id : nil
        page = page.first(limit)

        return [] if page.empty?

        execution_backed? ? rows_from_executions(page) : rows_from_jobs(page)
      end

      def paginated_records
        relation = filtered_relation
          .reorder(model.arel_table[:id].desc)
          .limit(limit + 1)

        relation = relation.where(model.arel_table[:id].lt(before_id)) if before_id
        relation.select(driving_columns).to_a
      end

      # Never `SELECT *`: it would drag a payload column through every list
      # query.
      def driving_columns
        (model.column_names - PAYLOAD_COLUMNS).map { |name| model.arel_table[name] }
      end

      def rows_from_executions(executions)
        job_ids = executions.map(&:job_id)
        jobs = jobs_by_id(job_ids)
        previews = argument_previews(job_ids)
        errors = state == :failed ? error_previews(executions.map(&:id)) : {}
        processes = state == :in_progress ? processes_by_id(executions.map(&:process_id)) : {}

        executions.filter_map do |execution|
          job = jobs[execution.job_id]
          next unless job

          JobRow.new(
            job: job,
            state: state,
            execution: execution,
            args_preview: previews[job.id],
            error_summary: errors[execution.id],
            process: processes[execution.try(:process_id)]
          )
        end
      end

      def rows_from_jobs(jobs)
        job_ids = jobs.map(&:id)
        previews = argument_previews(job_ids)
        annotations = state == :finished ? {} : JobRow.annotate(job_ids)

        jobs.map do |job|
          JobRow.new(
            job: job,
            state: JobRow.state_for(job, annotations[job.id]),
            args_preview: previews[job.id]
          )
        end
      end

      def jobs_by_id(job_ids)
        SolidQueue::Job.where(id: job_ids).select(SolidQueue::Job.column_names - PAYLOAD_COLUMNS).index_by(&:id)
      end

      def processes_by_id(process_ids)
        ids = process_ids.compact.uniq
        return {} if ids.empty?

        SolidQueue::Process.where(id: ids).select(:id, :name, :hostname, :pid, :kind).index_by(&:id)
      end

      # SUBSTR(col, 1, n) is the one truncation spelling SQLite, PostgreSQL and
      # MySQL all agree on, so no adapter switch is needed here.
      def argument_previews(job_ids)
        return {} if job_ids.empty?

        SolidQueue::Job
          .where(id: job_ids)
          .pluck(:id, Arel.sql("SUBSTR(arguments, 1, #{ARGUMENTS_PREVIEW_BYTES})"))
          .to_h
      end

      def error_previews(execution_ids)
        return {} if execution_ids.empty?

        SolidQueue::FailedExecution
          .where(id: execution_ids)
          .pluck(:id, Arel.sql("SUBSTR(error, 1, #{ERROR_PREVIEW_BYTES})"))
          .to_h { |id, raw| [ id, ErrorSummary.parse(raw) ] }
      end

      def apply_filters(relation)
        relation = relation.where.not(finished_at: nil) if state == :finished
        relation = relation.joins(:job) if join_jobs?

        relation = relation.where(jobs_table[:class_name].eq(class_name)) if class_name
        relation = relation.where(queue_table[:queue_name].eq(queue_name)) if queue_name
        relation = relation.where(jobs_table[:class_name].matches("#{escape_like(q)}%", nil, true)) if q

        relation
      end

      def join_jobs?
        return false unless execution_backed?

        class_name.present? || q.present? || (queue_name.present? && !own_queue_column?)
      end

      def own_queue_column?
        model.column_names.include?("queue_name")
      end

      def jobs_table = SolidQueue::Job.arel_table

      def queue_table
        own_queue_column? ? model.arel_table : jobs_table
      end

      def escape_like(value)
        ActiveRecord::Base.sanitize_sql_like(value.to_s)
      end
  end
end
