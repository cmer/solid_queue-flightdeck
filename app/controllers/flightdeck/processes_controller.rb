# frozen_string_literal: true

module Flightdeck
  class ProcessesController < ApplicationController
    include Toasts

    before_action :load_registry

    def index
    end

    # Pruning is Solid Queue's Process#prune: it fails the process's claimed
    # executions with a ProcessPrunedError and deregisters the row. Flightdeck
    # only decides *whether* a process may be pruned.
    def prune
      node = @registry.find(params[:id])
      return missing unless node

      unless node.prunable?
        toast "#{node.kind} #{node.name} is still sending heartbeats — only unresponsive " \
              "processes can be pruned.", level: :error
        return respond_with_toast(processes_frame, fallback: processes_path)
      end

      claimed = node.claimed_count
      node.process.prune
      load_registry

      toast "Pruned #{node.kind} #{node.name}#{released(claimed)}."
      respond_with_toast processes_frame, fallback: processes_path
    end

    private
      def load_registry
        @registry = ProcessRegistry.new
      end

      def processes_frame
        { id: "fd-processes", url: processes_path,
          partial: "flightdeck/processes/fleet", locals: { registry: @registry } }
      end

      def released(claimed)
        return "" if claimed.zero?

        " and released #{helpers.pluralize(claimed, "claimed execution")}"
      end

      def missing
        toast "That process is no longer registered.", level: :error
        respond_with_toast processes_frame, fallback: processes_path
      end
  end
end
