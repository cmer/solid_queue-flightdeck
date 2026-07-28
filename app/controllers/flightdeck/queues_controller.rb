# frozen_string_literal: true

module Flightdeck
  class QueuesController < ApplicationController
    include Toasts

    before_action :load_stats
    before_action :require_known_queue, only: %i[pause resume]

    def index
    end

    # Pausing and resuming are Solid Queue's own Queue#pause / #resume: they own
    # what a pause means, and Flightdeck never writes solid_queue_pauses itself.
    def pause
      SolidQueue::Queue.new(@queue_name).pause
      reload_stats
      toast "Paused #{@queue_name}. Workers will stop picking up its jobs."
      respond_with_toast queues_frame, fallback: queues_path
    end

    def resume
      SolidQueue::Queue.new(@queue_name).resume
      reload_stats
      toast "Resumed #{@queue_name}."
      respond_with_toast queues_frame, fallback: queues_path
    end

    private
      def load_stats
        @stats = QueueStats.new
        @sparklines = Metrics::Series.queue_sparklines
      end

      def reload_stats
        Flightdeck::Cache.bypass { load_stats }
      end

      def queues_frame
        { id: "fd-queues", url: queues_path,
          partial: "flightdeck/queues/cards", locals: { stats: @stats, sparklines: @sparklines } }
      end

      # Only queues Flightdeck is actually showing can be paused. That keeps an
      # arbitrary parameter from creating pause rows for queues that do not
      # exist.
      def require_known_queue
        @queue_name = params[:name].to_s

        return if @stats.find(@queue_name)

        toast "Unknown queue #{@queue_name.presence || "(blank)"}.", level: :error
        respond_with_toast queues_frame, fallback: queues_path
      end
  end
end
