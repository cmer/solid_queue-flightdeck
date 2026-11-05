# frozen_string_literal: true

module Flightdeck
  # Answers "who owns this job class?" from the host's CODEOWNERS file.
  #
  # Rules follow GitHub's: the last matching line wins, and a matching line with
  # no owners leaves the path unowned. Patterns are matched against the file
  # that defines the class, so components and engines resolve like any other
  # path. A class that can't be loaded or lives outside the repo has no owners.
  class Codeowners
    Rule = Struct.new(:regexp, :owners)

    # Directories CODEOWNERS may sit in; its patterns are relative to their parent.
    NESTED_IN = %w[.github .gitlab docs].freeze

    class << self
      # Read per request, not at boot, and re-parsed only when the file changes.
      def current
        path = Flightdeck.config.codeowners_path.presence
        return unless path

        path = File.realpath(path.to_s, Rails.root)
        mtime = File.mtime(path)
        return @current if @current && @current.path == path && @current.mtime == mtime

        @current = new(File.read(path, encoding: "UTF-8").scrub, path: path, mtime: mtime)
      rescue SystemCallError
        nil
      end
    end

    attr_reader :path, :mtime

    def initialize(source, path: nil, mtime: nil)
      @path = path
      @mtime = mtime
      @rules = source.each_line.filter_map { |line| parse(line) }
      @class_owners = Concurrent::Map.new
    end

    def owners_for_class(class_name)
      @class_owners.compute_if_absent(class_name) do
        file = relative_source_file(class_name)
        file ? owners_for_path(file) : []
      end
    end

    def owners_for_path(relative_path)
      @rules.reverse_each.find { |rule| rule.regexp.match?(relative_path) }&.owners || []
    end

    private
      def root
        directory = File.dirname(path)
        NESTED_IN.include?(File.basename(directory)) ? File.dirname(directory) : directory
      end

      # One broken job class must not take the page down with it, hence
      # ScriptError: a file that fails to load raises SyntaxError or LoadError.
      def relative_source_file(class_name)
        return unless class_name.safe_constantize

        file = File.realpath(Object.const_source_location(class_name).first)
        file.delete_prefix("#{root}/") if file.start_with?("#{root}/")
      rescue StandardError, ScriptError
        nil
      end

      def parse(line)
        pattern, *rest = line.scan(/(?:\\.|\S)+/)
        return if pattern.nil? || pattern.start_with?("#", "\\#")

        owners = rest.take_while { |token| !token.start_with?("#") }.map { |owner| display_name(owner) }
        Rule.new(regexp_for(pattern), owners)
      end

      # @acme/billing and @alice read as billing and alice; emails stay whole.
      def display_name(owner) = owner.delete_prefix("@").split("/").last

      def regexp_for(pattern)
        anchored = pattern.chomp("/").include?("/")
        # A trailing `/**` says what the descendants clause below already does.
        glob = pattern.delete_prefix("/").chomp("/").chomp("/**")
        # `dir/*` is direct children only; anything else also covers what's below.
        descendants = glob.end_with?("/*") ? "" : "(?:/.*)?"

        Regexp.new("\\A#{"(?:.*/)?" unless anchored}#{translate(glob)}#{descendants}\\z")
      end

      # `**` crosses directories only as a whole segment; elsewhere it is a `*`.
      def translate(glob)
        glob.gsub(%r{\\.?|(?<![^/])\*\*/|\*+|\?|[^*?\\]+}) do |token|
          case token
          when "**/" then "(?:.*/)?"
          when /\A\*/ then "[^/]*"
          when "?" then "[^/]"
          when /\A\\/ then Regexp.escape(token[1] || "\\")
          else Regexp.escape(token)
          end
        end
      end
  end
end
