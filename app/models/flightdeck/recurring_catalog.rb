# frozen_string_literal: true

module Flightdeck
  # The recurring schedule: every task, when it last ran, how that run went, and
  # when it is due next.
  #
  # "Next run" comes from the task's own Fugit-backed API rather than from a
  # calculation of ours, so Flightdeck and the scheduler can never disagree
  # about when something is due.
  class RecurringCatalog
    Row = Struct.new(:task, :last_run_at, :last_status, :last_job_id, keyword_init: true) do
      def id = task.id
      def key = task.key
      def schedule = task.schedule
      def queue_name = task.queue_name
      def priority = task.priority
      def description = task.description
      def static? = task.static?

      def job_class
        task.class_name.presence || task.command.presence || "(command)"
      end

      def human_schedule
        CronSchedule.humanize(schedule)
      end

      # Fugit raises on schedules it cannot parse. A task that is on screen but
      # unparseable should show "—" rather than take the page down.
      def next_run_at
        @next_run_at ||= task.next_time
      rescue StandardError
        nil
      end

      def next_run_in
        next_run_at && next_run_at - Time.current
      end

      def failed? = last_status == :failed
      def ever_run? = last_run_at.present?
    end

    def rows
      @rows ||= tasks.map do |task|
        run = last_runs[task.key]

        Row.new(
          task: task,
          last_run_at: run&.first,
          last_job_id: run&.last,
          last_status: status_for(run&.last)
        )
      end
    end

    def find(id)
      rows.find { |row| row.id == id.to_i }
    end

    def any? = rows.any?

    private
      def tasks
        @tasks ||= SolidQueue::RecurringTask.order(:key).to_a
      end

      def keys = tasks.map(&:key)

      # [run_at, job_id] of the most recent execution of each task, in two
      # queries: the maximum run_at per key, then the rows that match them.
      def last_runs
        @last_runs ||= compute_last_runs
      end

      def compute_last_runs
        return {} if keys.empty?

        maxima = SolidQueue::RecurringExecution.where(task_key: keys).group(:task_key).maximum(:run_at)
        return {} if maxima.empty?

        SolidQueue::RecurringExecution
          .where(task_key: maxima.keys, run_at: maxima.values)
          .pluck(:task_key, :run_at, :job_id)
          .each_with_object({}) do |(task_key, run_at, job_id), found|
            next unless maxima[task_key] == run_at

            found[task_key] = [ run_at, job_id ]
          end
      end

      def status_for(job_id)
        return nil if job_id.nil?
        # The job has been purged by clear_finished_jobs_after: we know it ran,
        # but not how it went. Say so rather than claim success.
        return :unknown unless surviving_job_ids.include?(job_id)

        failed_job_ids.include?(job_id) ? :failed : :ok
      end

      def last_job_ids
        @last_job_ids ||= last_runs.values.filter_map(&:last)
      end

      def surviving_job_ids
        @surviving_job_ids ||= last_job_ids.empty? ? Set.new : SolidQueue::Job.where(id: last_job_ids).pluck(:id).to_set
      end

      def failed_job_ids
        @failed_job_ids ||=
          last_job_ids.empty? ? Set.new : SolidQueue::FailedExecution.where(job_id: last_job_ids).pluck(:job_id).to_set
      end
  end
end
