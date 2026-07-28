# frozen_string_literal: true

module Flightdeck
  module Metrics
    # Average completion time: area under a line, with gaps where no jobs
    # finished at all.
    class LineChart < Chart
      DOT_RADIUS = 3

      def coordinates
        @coordinates ||= points.each_with_index.map do |point, index|
          next nil if point.seconds.nil?

          { x: round(plot_left + (slot_width * index) + (slot_width / 2.0)),
            y: round(y_for(point.seconds)),
            seconds: point.seconds,
            title: point_title(point) }
        end
      end

      # Contiguous runs of buckets that had data. Drawing them separately keeps
      # a gap in the data looking like a gap, instead of a straight line across
      # a period we know nothing about.
      def segments
        coordinates.chunk_while { |a, b| !a.nil? && !b.nil? }.filter_map do |chunk|
          present = chunk.compact
          present.size.positive? ? present : nil
        end
      end

      def line_path(segment)
        return "" if segment.empty?

        segment.each_with_index.map { |c, i| "#{i.zero? ? "M" : "L"} #{c[:x]} #{c[:y]}" }.join(" ")
      end

      def area_path(segment)
        return "" if segment.empty?

        "#{line_path(segment)} L #{segment.last[:x]} #{plot_bottom} L #{segment.first[:x]} #{plot_bottom} Z"
      end

      def markers = coordinates.compact

      def last_marker = markers.last

      def any_data? = markers.any?

      private
        def raw_max = points.filter_map(&:seconds).max.to_f

        # The zero gridline reads "0s" rather than "0ms": it is an axis origin,
        # not a measurement.
        def format_value(value)
          value.zero? ? "0s" : Flightdeck::Duration.humanize(value)
        end

        def point_title(point)
          "#{full_time(point.at)} · avg #{format_value(point.seconds)} to completion"
        end
    end
  end
end
