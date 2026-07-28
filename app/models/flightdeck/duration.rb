# frozen_string_literal: true

module Flightdeck
  # The one way a number of seconds is written anywhere in Flightdeck —
  # list columns, overview tiles and chart axes all speak through this, so
  # "how long" can never be spelled three subtly different ways.
  module Duration
    module_function

    def humanize(seconds)
      value = seconds.to_f.abs
      case value
      when 0...1 then "#{(value * 1000).round}ms"
      when 1...60 then "#{trim(value.round(1))}s"
      when 60...3600 then "#{(value / 60).round}m"
      when 3600...86_400 then "#{trim((value / 3600).round(1))}h"
      else "#{trim((value / 86_400).round(1))}d"
      end
    end

    def trim(number) = number.to_s.sub(/\.0\z/, "")
  end
end
