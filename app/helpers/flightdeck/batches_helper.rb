# frozen_string_literal: true

module Flightdeck
  module BatchesHelper
    STATE_LABELS = {
      all: "All",
      unfinished: "Unfinished",
      completed: "Completed",
      failed: "Failed",
      pending: "Pending",
      enqueued: "Enqueued"
    }.freeze

    PILL_CLASSES = {
      pending: "scheduled",
      enqueued: "progress",
      completed: "finished",
      failed: "failed"
    }.freeze

    def fd_batch_state_label(state) = STATE_LABELS.fetch(state.to_sym, state.to_s.humanize)

    def fd_batch_state_pill(state)
      tag.span(fd_batch_state_label(state).upcase,
               class: "fd-pill #{PILL_CLASSES.fetch(state.to_sym, "scheduled")}")
    end

    def fd_batch_progress_bar(row)
      tag.svg(class: "fd-batch-bar", viewBox: "0 0 100 4", preserveAspectRatio: "none", "aria-hidden": true) do
        safe_join([
          tag.rect(class: "fd-depth-track", width: 100, height: 4),
          (tag.rect(class: "fd-batch-fill-ok", width: row.completed_share, height: 4) if row.completed_share.positive?),
          (tag.rect(class: "fd-batch-fill-bad", x: row.completed_share, width: row.failed_share, height: 4) if row.failed_share.positive?)
        ])
      end
    end

    def fd_batch_progress_counts(row)
      parts = [ "#{number_with_delimiter(row.completed_jobs)} completed" ]
      parts << "#{number_with_delimiter(row.failed_jobs)} failed" if row.failed_jobs.positive?
      parts << "#{number_with_delimiter(row.pending_jobs)} pending" if row.pending_jobs.positive?
      "#{parts.join(" · ")} of #{number_with_delimiter(row.total_jobs)}"
    end

    def fd_current_batches_url
      batches_path(request.query_parameters)
    end

    def fd_current_batch_url(batch)
      batch_path(batch.id, request.query_parameters.slice("before_id"))
    end

    def dom_id_for_batch(id) = "fd-batch-#{id}"
  end
end
