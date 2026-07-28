# frozen_string_literal: true

module Flightdeck
  # Everything the job show page needs, assembled from Solid Queue's own models.
  #
  # Arguments are shown exactly as they were stored. They are never handed to
  # ActiveJob for deserialization: that would load host application classes (and
  # run their code) just to render a dashboard.
  class JobDetail
    ARGUMENTS_DISPLAY_LIMIT = 10.kilobytes

    # A frame belongs to the application unless it lives in an installed gem or
    # in Ruby's own library directories.
    VENDOR_FRAME = %r{
      (?:\A|/)(?:gems|ruby|rubygems|bundler|vendor/bundle)/ |
      \A<internal: | \A/usr/lib/ruby/
    }x

    attr_reader :job, :state, :execution, :process

    def self.find(id)
      job = SolidQueue::Job.find(id)
      annotation = JobRow.annotate([ job.id ])[job.id]

      new(job: job, annotation: annotation)
    end

    def initialize(job:, annotation: nil)
      @job = job
      @state = JobRow.state_for(job, annotation)
      @execution = load_execution(annotation)
      @process = load_process
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
    def retryable? = failed?
    def discardable? = state != :in_progress && state != :finished

    def failed_execution
      execution if failed?
    end

    # --- arguments ----------------------------------------------------------

    # `job.arguments` is already a Ruby structure (Solid Queue stores it with a
    # JSON coder); pretty-printing it is a formatting step, not deserialization.
    def arguments_json
      @arguments_json ||= begin
        JSON.pretty_generate(job.arguments)
      rescue StandardError
        job.arguments.to_s
      end
    end

    def arguments_truncated?
      arguments_json.bytesize > ARGUMENTS_DISPLAY_LIMIT
    end

    def arguments_preview
      return arguments_json unless arguments_truncated?

      arguments_json.byteslice(0, ARGUMENTS_DISPLAY_LIMIT).scrub("")
    end

    def arguments_bytes = arguments_json.bytesize

    # --- error --------------------------------------------------------------

    def error_class
      failed_execution&.exception_class
    end

    def error_message
      failed_execution&.message
    end

    def backtrace
      @backtrace ||= Array(failed_execution&.backtrace).first(Flightdeck.config.backtrace_lines)
    end

    def backtrace_total = Array(failed_execution&.backtrace).size

    def backtrace_truncated? = backtrace_total > backtrace.size

    def backtrace_frames
      backtrace.map { |line| { line: line, app: app_frame?(line) } }
    end

    def app_frame?(line)
      !VENDOR_FRAME.match?(line.to_s)
    end

    # --- timeline -----------------------------------------------------------

    Event = Struct.new(:label, :at, :detail, :status, keyword_init: true)

    # Built only from timestamps Solid Queue actually keeps. Steps whose row has
    # already been consumed (a finished job's claim, say) are simply absent
    # rather than invented.
    def timeline
      events = [ Event.new(label: "Enqueued", at: enqueued_at, detail: "queue #{queue_name}", status: :ok) ]

      if scheduled_at.present? && scheduled_at > enqueued_at
        events << Event.new(label: "Scheduled", at: scheduled_at,
                            detail: scheduled_at.future? ? "not yet due" : "became due", status: :ok)
      end

      case state
      when :ready
        events << Event.new(label: "Ready", at: execution&.created_at, detail: "waiting for a worker", status: :now)
      when :blocked
        events << Event.new(label: "Blocked", at: execution&.created_at,
                            detail: "concurrency key #{job.concurrency_key}", status: :now)
      when :in_progress
        events << Event.new(label: "Claimed", at: execution&.created_at, detail: process_label, status: :now)
      when :failed
        events << Event.new(label: "Failed", at: execution&.created_at, detail: error_class, status: :bad)
        events << Event.new(label: "Awaiting decision", at: nil,
                            detail: "retry or discard", status: :now)
      end

      events << Event.new(label: "Finished", at: finished_at, detail: nil, status: :ok) if finished_at.present?
      events.select { |event| event.at.present? || event.status == :now }
    end

    def process_label
      return nil unless process

      [ process.name, ("pid #{process.pid}" if process.pid) ].compact.join(" · ")
    end

    private
      def load_execution(annotation)
        return nil unless annotation

        model = JobRow.model_for(state)
        model&.find_by(id: annotation[:execution_id])
      end

      def load_process
        return nil unless execution.respond_to?(:process_id) && execution.process_id

        SolidQueue::Process.find_by(id: execution.process_id)
      end
  end
end
