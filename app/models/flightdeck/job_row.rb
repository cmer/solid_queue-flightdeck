# frozen_string_literal: true

module Flightdeck
  # One row of a jobs list. Deliberately dumb: JobsQuery assembles these from
  # bounded queries and the view asks them formatting questions.
  class JobRow
    # Every table a job can be sitting in, in the order we report them. A job is
    # only ever in one of these at a time, but we probe all five so a row is
    # never silently mislabelled during a transition.
    EXECUTION_MODELS = {
      ready: "SolidQueue::ReadyExecution",
      scheduled: "SolidQueue::ScheduledExecution",
      in_progress: "SolidQueue::ClaimedExecution",
      blocked: "SolidQueue::BlockedExecution",
      failed: "SolidQueue::FailedExecution"
    }.freeze

    class << self
      def model_for(state)
        name = EXECUTION_MODELS[state.to_sym]
        name && name.constantize
      end

      # How a job's state is derived, in one place: `finished_at` wins, then
      # whichever execution table `annotate` found the job in, then :unknown
      # for the transition window where a job is between tables.
      def state_for(job, annotation)
        return :finished if job.finished_at.present?
        return annotation[:state] if annotation

        :unknown
      end

      # Resolves the state of an already-loaded page of jobs with one
      # `WHERE job_id IN (page_ids)` lookup per executions table. Returns
      # { job_id => { state:, execution_id:, process_id: } }.
      def annotate(job_ids)
        job_ids = Array(job_ids).compact.uniq
        return {} if job_ids.empty?

        EXECUTION_MODELS.each_with_object({}) do |(state, model_name), found|
          model = model_name.constantize
          columns = [ :id, :job_id ]
          columns << :process_id if model.column_names.include?("process_id")

          model.where(job_id: job_ids).pluck(*columns).each do |values|
            job_id = values[1]
            next if found.key?(job_id)

            found[job_id] = { state: state, execution_id: values[0], process_id: values[2] }
          end
        end
      end
    end

    attr_reader :job, :state, :execution, :args_preview, :error_summary, :process

    def initialize(job:, state:, execution: nil, args_preview: nil, error_summary: nil, process: nil)
      @job = job
      @state = state
      @execution = execution
      @args_preview = args_preview
      @error_summary = error_summary || ErrorSummary.none
      @process = process
    end

    def id = job.id
    def class_name = job.class_name
    def queue_name = job.queue_name
    def priority = job.priority
    def active_job_id = job.active_job_id
    def concurrency_key = job.concurrency_key
    def enqueued_at = job.created_at
    def scheduled_at = job.scheduled_at
    def finished_at = job.finished_at

    def failed? = state == :failed
    def discardable? = state != :in_progress

    # The moment the job first became eligible to run — what "waiting" is
    # measured from, so a job scheduled for next week is not reported as having
    # waited a week.
    def due_at
      scheduled_at || enqueued_at
    end

    def execution_started_at
      execution&.created_at if state == :in_progress
    end

    def failed_at
      execution&.created_at if failed?
    end

    # Attempt number, when ActiveJob recorded one in the serialized payload. We
    # only ever see a truncated prefix of the arguments, so this is best-effort
    # by design and returns nil rather than guessing.
    def attempts
      value = args_preview.to_s[/"executions"\s*:\s*(\d+)/, 1]
      value && value.to_i + 1
    end
  end
end
