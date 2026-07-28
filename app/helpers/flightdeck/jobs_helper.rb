# frozen_string_literal: true

module Flightdeck
  module JobsHelper
    STATE_LABELS = {
      all: "All",
      ready: "Ready",
      scheduled: "Scheduled",
      in_progress: "In progress",
      blocked: "Blocked",
      finished: "Finished",
      failed: "Failed",
      unknown: "Unknown"
    }.freeze

    PILL_CLASSES = {
      ready: "ready",
      scheduled: "scheduled",
      in_progress: "progress",
      blocked: "blocked",
      finished: "finished",
      failed: "failed",
      unknown: "scheduled"
    }.freeze

    def fd_state_label(state) = STATE_LABELS.fetch(state.to_sym, state.to_s.humanize)

    def fd_state_pill(state)
      tag.span(fd_state_label(state).upcase,
               class: "fd-pill #{PILL_CLASSES.fetch(state.to_sym, "scheduled")}")
    end

    def fd_queue_badge(queue_name)
      tag.span(queue_name.presence || "—", class: "fd-qbadge")
    end

    # Counts are capped by JobsQuery, so a capped value is rendered as "500,000+"
    # rather than pretending to be exact.
    def fd_count(count, capped: false)
      "#{number_with_delimiter(count)}#{"+" if capped}"
    end

    def fd_time(time)
      return "—" if time.blank?

      tag.span(time.in_time_zone(Flightdeck.config.display_timezone).strftime("%H:%M:%S"),
               title: fd_full_time(time))
    end

    def fd_full_time(time)
      return "—" if time.blank?

      time.in_time_zone(Flightdeck.config.display_timezone).strftime("%Y-%m-%d %H:%M:%S %Z")
    end

    def fd_duration(seconds)
      seconds.nil? ? "—" : Flightdeck::Duration.humanize(seconds)
    end

    def fd_ago(time)
      return "—" if time.blank?

      "#{fd_duration(Time.current - time)} ago"
    end

    # Best-effort "what has this job been doing" column. Only ever derived from
    # timestamps Solid Queue actually keeps — nothing here is estimated.
    def fd_progress_label(row)
      case row.state
      when :ready
        "waited #{fd_duration(Time.current - row.due_at)}"
      when :scheduled
        row.scheduled_at&.future? ? "due in #{fd_duration(row.scheduled_at - Time.current)}" : "due now"
      when :in_progress
        started = row.execution_started_at
        return "running" unless started

        "waited #{fd_duration(started - row.due_at)} · running #{fd_duration(Time.current - started)}"
      when :blocked
        row.concurrency_key.presence ? "concurrency: #{row.concurrency_key}" : "blocked"
      when :finished
        row.finished_at ? "total #{fd_duration(row.finished_at - row.enqueued_at)}" : "—"
      when :failed
        row.failed_at ? "failed after #{fd_duration(row.failed_at - row.due_at)}" : "—"
      else
        "—"
      end
    end

    # Shows the job's own arguments rather than the ActiveJob envelope they
    # are wrapped in; see Flightdeck::ArgumentsPreview.
    def fd_args_preview(preview, length: 120)
      Flightdeck::ArgumentsPreview.format(preview, length: length)
    end

    # The frame refreshes itself by re-requesting the URL it is showing, so
    # filters, state tab and cursor all survive a poll.
    def fd_current_list_url
      jobs_path(request.query_parameters)
    end

    def dom_id_for_job(id) = "fd-job-#{id}"

    # Under an exception-class group header, repeating the class on every row is
    # noise — the message is the part that differs.
    def fd_error_cell(summary, grouped: false)
      return "—" unless summary.present?

      text = grouped ? summary.message.presence || summary.exception_class : summary.to_s
      text.to_s
    end

    def fd_toast_level_class(level)
      level.to_sym == :error ? "fd-toast error" : "fd-toast"
    end
  end
end
