# frozen_string_literal: true

module Flightdeck
  # Progress counts are injected so a page of unfinished batches does not each
  # fire their own live counter queries.
  class BatchRow
    attr_reader :batch, :pending_jobs, :completed_jobs, :failed_jobs

    def initialize(batch:, pending_jobs:, completed_jobs:, failed_jobs:)
      @batch = batch
      @pending_jobs = pending_jobs
      @completed_jobs = completed_jobs
      @failed_jobs = failed_jobs
    end

    delegate :id, :description, :total_jobs, :enqueued_at, :finished_at,
             :failed_at, :created_at, :active_job_batch_id, :status, to: :batch

    def title
      description.presence || "Batch ##{id}"
    end

    def completed_share
      share(completed_jobs)
    end

    def failed_share
      remaining = 100 - completed_share
      [ share(failed_jobs), remaining ].min
    end

    private
      def share(count)
        return 0 if total_jobs.to_i.zero?

        [ (count.to_f / total_jobs * 100).round, 100 ].min
      end
  end
end
