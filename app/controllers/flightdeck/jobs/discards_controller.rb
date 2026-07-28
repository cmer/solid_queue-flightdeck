# frozen_string_literal: true

module Flightdeck
  module Jobs
    # Discarding delegates to Solid Queue's Execution#discard, which destroys the
    # job and its execution row together and lets Solid Queue release whatever
    # concurrency locks the job was holding.
    #
    # A job that is currently being executed cannot be discarded — Solid Queue
    # raises UndiscardableError, and Flightdeck surfaces that rather than trying
    # to work around it.
    class DiscardsController < ActionsController
      DISCARDABLE_STATES = %i[ready scheduled blocked failed].freeze

      private
        def target_relation
          scoped_query(state: discard_state).filtered_relation
        end

        def discard_state
          state = params[:state].presence&.to_sym || :failed
          DISCARDABLE_STATES.include?(state) ? state : :failed
        end

        # A single discard may arrive from any list, so look for the job in every
        # table it could legitimately be sitting in rather than trusting the
        # state the page happened to be showing.
        def find_single(job_id)
          DISCARDABLE_STATES.lazy.filter_map do |state|
            JobRow.model_for(state).find_by(job_id: job_id)
          end.first
        end

        def apply(execution)
          execution.discard
        end

        def past_tense = "discarded"
        def blocked_reason = "discardable"
        def default_state = discard_state
    end
  end
end
