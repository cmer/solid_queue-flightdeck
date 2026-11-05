# frozen_string_literal: true

module Flightdeck
  module OwnersHelper
    # A count that opens the failed jobs behind it. Zero has nothing to open.
    def fd_failed_count_link(count, **filters)
      label = number_with_delimiter(count)
      count.zero? ? label : link_to(label, jobs_path(state: :failed, **filters))
    end
  end
end
