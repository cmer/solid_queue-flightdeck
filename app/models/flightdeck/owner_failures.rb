# frozen_string_literal: true

module Flightdeck
  # Failed jobs per class, with the owners of each class.
  #
  # Solid Queue deletes a failed execution when its job is retried or discarded,
  # so a window counts jobs that failed in it and are still failed. It is not a
  # history of failures.
  class OwnerFailures
    WINDOWS = JobsQuery::FAILED_WINDOWS
    UNOWNED = "Unowned"

    Row = Struct.new(:class_name, :owners, :total, :windows, keyword_init: true)

    attr_reader :owner, :q

    def initialize(codeowners, owner: nil, q: nil)
      @codeowners = codeowners
      @owner = owner
      @q = q
    end

    def filtered? = owner.present? || q.present?

    def rows
      searched_rows.select { |row| owner.nil? || labels(row).include?(owner) }
    end

    def total = rows.sum(&:total)

    def window_totals
      WINDOWS.keys.each_index.map { |index| rows.sum { |row| row.windows[index] } }
    end

    # Largest first, Unowned last. A class with two owners counts for both. The
    # selected owner stays listed at zero, or it could not be seen or changed.
    def owner_totals
      totals = Hash.new(0)
      searched_rows.each { |row| labels(row).each { |label| totals[label] += row.total } }
      totals[owner] += 0 if owner
      unowned = totals.delete(UNOWNED)
      sorted = totals.sort_by { |label, count| [ -count, label ] }.to_h
      unowned ? sorted.merge(UNOWNED => unowned) : sorted
    end

    private
      def labels(row) = row.owners.presence || [ UNOWNED ]

      # Case-insensitive substring. Every class is already in memory here, so
      # this costs no extra query.
      def searched_rows
        return all_rows unless q

        needle = q.downcase
        all_rows.select { |row| row.class_name.downcase.include?(needle) }
      end

      def all_rows
        @all_rows ||= counts
          .map do |class_name, total, *windows|
            Row.new(class_name: class_name, owners: @codeowners.owners_for_class(class_name),
                    total: total.to_i, windows: windows.map(&:to_i))
          end
          .sort_by { |row| [ -row.total, row.class_name ] }
      end

      # Owners stay out of the cached value, so a CODEOWNERS change shows at once.
      def counts
        Cache.fetch("owner_failures", expires_in: Flightdeck.config.chart_cache_ttl) { count_by_class }
      end

      def count_by_class
        failed = SolidQueue::FailedExecution.arel_table
        class_name = SolidQueue::Job.arel_table[:class_name]
        now = Time.current
        in_window = WINDOWS.values.map do |length|
          Arel::Nodes::Case.new.when(failed[:created_at].gteq(now - length)).then(1).else(0).sum
        end

        SolidQueue::FailedExecution.joins(:job).group(class_name).pluck(class_name, failed[:id].count, *in_window)
      end
  end
end
