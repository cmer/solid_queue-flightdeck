# frozen_string_literal: true

module Flightdeck
  # Everything the batch show page needs. Callback payloads are treated as
  # JSON — they are never handed to ActiveJob to deserialize.
  class BatchDetail < BatchRow
    def self.find(id)
      raise ActiveRecord::RecordNotFound, "Batches are not available" unless BatchesQuery.available?

      batch = SolidQueue::Batch.find(id)
      new(batch: batch, **BatchesQuery.progress_for([ batch ]).fetch(batch.id))
    end

    def metadata
      batch.metadata
    rescue StandardError
      {}
    end

    def metadata? = metadata.present?

    def metadata_json
      JSON.pretty_generate(metadata)
    rescue StandardError
      metadata.to_s
    end

    def callbacks
      [
        [ "On finish", :on_finish ],
        [ "On success", :on_success ],
        [ "On failure", :on_failure ]
      ].filter_map do |label, name|
        job_class = callback_class(name)
        [ label, job_class ] if job_class.present?
      end
    end

    private
      def callback_class(name)
        value = batch.public_send(name)
        value["job_class"].presence if value.is_a?(Hash)
      rescue StandardError
        nil
      end
  end
end
