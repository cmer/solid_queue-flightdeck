# frozen_string_literal: true

module Flightdeck
  class BatchesController < ApplicationController
    rescue_from BatchesQuery::InvalidState, with: :unknown_state
    rescue_from ActiveRecord::RecordNotFound, with: :batch_gone

    before_action :require_batches!

    def index
      @query = BatchesQuery.new(state: state_param, before_id: params[:before_id])
      @rows = @query.rows
      @state_counts = BatchesQuery.state_counts
    end

    def show
      @batch = BatchDetail.find(params[:id])
      @jobs_query = JobsQuery.new(batch_id: @batch.id, before_id: params[:before_id])
      @rows = @jobs_query.rows
    end

    private
      def require_batches!
        return if BatchesQuery.available?

        redirect_to root_path, alert: "Batches are not available on this Solid Queue installation."
      end

      def state_param
        value = params[:state].presence&.to_sym || :all
        raise BatchesQuery::InvalidState, "unknown batch state #{params[:state].inspect}" unless BatchesQuery::STATES.include?(value)

        value
      end

      def unknown_state
        redirect_to batches_path, alert: "Unknown batch state."
      end

      def batch_gone
        redirect_to batches_path, alert: "That batch no longer exists."
      end
  end
end
