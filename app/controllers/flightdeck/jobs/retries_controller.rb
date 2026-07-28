# frozen_string_literal: true

module Flightdeck
  module Jobs
    # Retrying is Solid Queue's own FailedExecution#retry: it resets the job's
    # execution counters, re-dispatches it and deletes the failure row, all
    # under a lock. Flightdeck never reimplements any of that.
    class RetriesController < ActionsController
      private
        def target_relation
          scoped_query(state: :failed).filtered_relation
        end

        def apply(execution)
          execution.retry
        end

        def past_tense = "retried"
        def blocked_reason = "failed"
    end
  end
end
