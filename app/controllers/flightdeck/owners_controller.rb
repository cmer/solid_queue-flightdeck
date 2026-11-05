# frozen_string_literal: true

module Flightdeck
  class OwnersController < ApplicationController
    def index
      @codeowners = Codeowners.current
      @failures = OwnerFailures.new(@codeowners, **owner_filters) if @codeowners
    end

    private
      def owner_filters
        { owner: params[:owner].to_s.presence, q: params[:q].to_s.strip.presence }
      end
  end
end
