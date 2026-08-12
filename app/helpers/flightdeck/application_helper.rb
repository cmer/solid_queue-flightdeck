# frozen_string_literal: true

module Flightdeck
  module ApplicationHelper
    # The polling <turbo-frame> every panel lives in: the refresh Stimulus
    # controller, its interval, and the URL the frame re-requests. One owner for
    # the markup, so the index views and the turbo-stream replacements can never
    # drift apart.
    #
    # `target:` defaults to "_top" because most frames are lists whose links
    # leave the frame; the jobs list opts out (`target: nil`) so its pager can
    # navigate in place.
    def fd_refresh_frame(id, url:, interval: fd_poll_ms, target: "_top", **options, &block)
      tag.turbo_frame(
        id: id,
        target: target,
        data: { controller: "refresh", refresh_interval_value: interval, refresh_url_value: url },
        **options, &block
      )
    end

    # Path to a built asset, resolved through the committed manifest. Returns
    # nil when assets have not been built yet (fresh checkout / dev), so the
    # layout can simply omit the tag instead of blowing up.
    def flightdeck_asset_path(logical_name)
      digested = Flightdeck::Assets.digested_name(logical_name)
      return nil unless digested

      asset_file_path(name: digested)
    end

    # The host's configured typeface, stamped on <html> so the first paint is
    # already correct. A user's own choice replaces it once the font controller
    # connects.
    def fd_ui_font
      Flightdeck.config.ui_font
    end

    def fd_ui_font_options
      Flightdeck::UiFonts.options
    end

    # Sidebar counts are capped like every other count, and degrade to "—"
    # rather than taking the whole page down if the queue database is
    # unreachable.
    def fd_nav_count(state)
      query = Flightdeck::JobsQuery.new(state: state)
      fd_count(query.count, capped: query.count_capped?)
    rescue ActiveRecord::ActiveRecordError
      "—"
    end

    # Infrastructure counts, cached like every other count and degrading to "—"
    # rather than taking the whole page down if the queue database is away.
    def fd_nav_queue_count
      nav_count("queues") { Flightdeck::QueueStats.new.rows.size }
    end

    def fd_nav_process_count
      nav_count("processes") { SolidQueue::Process.count }
    end

    def fd_nav_recurring_count
      nav_count("recurring") { SolidQueue::RecurringTask.count }
    end

    def fd_nav_any_dead_processes?
      nav_count("dead_processes") do
        SolidQueue::Process.where(last_heartbeat_at: ..SolidQueue.process_alive_threshold.ago).exists?
      end == true
    end

    def fd_nav_active?(state)
      return false unless controller_name == "jobs" && action_name == "index"

      current = params[:state].presence&.to_sym || :all
      current == state
    end

    def nav_count(name, &block)
      Flightdeck::Cache.fetch("nav", name, expires_in: Flightdeck.config.poll_interval, &block)
    rescue ActiveRecord::ActiveRecordError
      "—"
    end

    def flightdeck_brand_svg(size: 26)
      tag.svg(width: size, height: size, viewBox: "0 0 26 26", fill: "none", "aria-hidden": true) do
        safe_join([
          tag.circle(cx: 13, cy: 13, r: 11.5, stroke: "var(--accent-ink)", "stroke-width": 1.6),
          tag.path(d: "M3 15 C 8 10.5, 18 10.5, 23 15", stroke: "var(--accent-ink)", "stroke-width": 1.6, fill: "none"),
          tag.path(d: "M9.5 13.2 h7 M13 11.4 v1.8", stroke: "var(--ink)", "stroke-width": 1.6, "stroke-linecap": "round")
        ])
      end
    end
  end
end
