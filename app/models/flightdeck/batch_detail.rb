# frozen_string_literal: true

module Flightdeck
  # Everything the batch show page needs. Callback payloads are treated as
  # JSON — they are never handed to ActiveJob to deserialize.
  class BatchDetail
    attr_reader :row

    def self.find(id)
      raise ActiveRecord::RecordNotFound, "Batches are not available" unless BatchesQuery.available?

      new(SolidQueue::Batch.find(id))
    end

    def initialize(batch)
      @batch = batch
      counts = BatchesQuery.progress_for([ batch ]).fetch(batch.id)
      @row = BatchRow.new(batch: batch, **counts)
    end

    delegate :id, :title, :status, :total_jobs, :pending_jobs,
             :completed_jobs, :failed_jobs, :completed_share, :failed_share,
             :enqueued_at, :finished_at, :failed_at, :created_at,
             :active_job_batch_id, to: :row

    def metadata
      @batch.metadata
    rescue StandardError
      {}
    end

    def metadata? = metadata.present?

    def metadata_json
      JSON.pretty_generate(metadata)
    rescue StandardError
      metadata.to_s
    end

    def on_finish_class = callback_class(@batch.on_finish)
    def on_success_class = callback_class(@batch.on_success)
    def on_failure_class = callback_class(@batch.on_failure)

    private
      def callback_class(value)
        return unless value.is_a?(Hash)

        value["job_class"].presence || value[:job_class].presence
      end
  end
end
