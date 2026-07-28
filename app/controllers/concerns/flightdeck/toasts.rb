# frozen_string_literal: true

module Flightdeck
  # Shared response shape for every mutating action: a toast plus a re-rendered
  # polling frame over Turbo Streams, or a redirect carrying the same sentence
  # in the flash when Turbo is not in play.
  #
  # The frame is described as data — `{ id:, url:, partial:, locals: }` — and
  # rendered by the one shared template, so every controller's stream response
  # is the same markup by construction.
  module Toasts
    private
      def toast(message, level: :success, continuable: false)
        @toast = { message: message, level: level, continuable: continuable }
      end

      def respond_with_toast(frame, fallback:)
        respond_to do |format|
          format.turbo_stream { render_refresh_stream(frame) }
          format.any { redirect_with_toast_flash(fallback) }
        end
      end

      def render_refresh_stream(frame)
        @frame = frame
        render "flightdeck/shared/refresh", formats: :turbo_stream
      end

      # The one place that knows how a toast level maps onto the flash.
      def redirect_with_toast_flash(fallback)
        flash[@toast[:level] == :error ? :alert : :notice] = @toast[:message]
        redirect_to fallback
      end
  end
end
