# frozen_string_literal: true

module Flightdeck
  class RecurringTasksController < ApplicationController
    include Toasts

    before_action :load_catalog

    def index
    end

    # "Run now" is the task's own enqueue, so the recurring execution is
    # recorded exactly as the scheduler would have recorded it.
    def run
      row = @catalog.find(params[:id])
      return missing unless row

      active_job = row.task.enqueue(at: Time.current)
      load_catalog

      if active_job
        @enqueued_job_id = active_job.try(:provider_job_id)
        toast "Enqueued #{row.key}#{job_reference}."
      else
        toast "#{row.key} was not enqueued — it has already run for this slot, or the job " \
              "class refused to enqueue.", level: :error
      end

      respond_with_toast recurring_frame, fallback: recurring_tasks_path
    end

    private
      def load_catalog
        @catalog = RecurringCatalog.new
      end

      def recurring_frame
        { id: "fd-recurring", url: recurring_tasks_path,
          partial: "flightdeck/recurring_tasks/table", locals: { catalog: @catalog } }
      end

      def job_reference
        @enqueued_job_id ? " as job ##{@enqueued_job_id}" : ""
      end

      def missing
        toast "That recurring task no longer exists.", level: :error
        respond_with_toast recurring_frame, fallback: recurring_tasks_path
      end
  end
end
