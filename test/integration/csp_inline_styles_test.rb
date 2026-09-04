# frozen_string_literal: true

require "test_helper"

# A nonce cannot rescue an inline style *attribute*: those are governed by
# style-src-attr, which falls back to style-src, so a strict `style-src 'self'`
# blocks every one of them — column widths collapse and the queue depth bars
# vanish. The dashboard therefore renders no style attributes at all; widths and
# fills belong in the stylesheet or in SVG geometry attributes.
class Flightdeck::CspInlineStylesTest < FlightdeckIntegrationTest
  test "no dashboard page renders an inline style attribute" do
    seed_everything

    dashboard_paths.each { |path| assert_no_inline_styles(path) }
  end

  # Guards against the assertion above passing vacuously: the depth bar is the
  # one width that varies per request, so it has to be on the page and non-zero.
  test "the overview renders a non-zero queue depth bar without inline styles" do
    seed_everything

    get_fd "/flightdeck"
    fills = Nokogiri::HTML(response.body).css(".fd-depth-bar .fd-depth-fill")

    assert_predicate fills, :any?, "expected the overview to render queue depth bars"
    assert fills.any? { |fill| fill["width"].to_i.positive? },
           "expected at least one queue with a non-zero depth, or this test proves nothing"
  end

  private
    def dashboard_paths
      paths = %w[/flightdeck /flightdeck/queues /flightdeck/processes /flightdeck/recurring_tasks]
      paths += Flightdeck::JobsQuery::STATES.map { |state| "/flightdeck/jobs?state=#{state}" }
      paths + @job_paths
    end

    def assert_no_inline_styles(path)
      get_fd path
      assert_response :success, "#{path} did not render"

      styled = Nokogiri::HTML(response.body).css("[style]")
      assert_empty styled.map { |element| element.to_html.truncate(120) },
                   "#{path} renders inline style attributes; move them into assets-src/input.css " \
                   "(or an SVG geometry attribute) so a strict CSP cannot break the layout"
    end

    def seed_everything
      scenario = create_full_scenario
      create_fleet
      task = create_recurring_task(key: "digest")
      record_recurring_run(task, run_at: 1.hour.ago)
      create_finished_job(queue_name: "critical", finished_at: 30.minutes.ago)

      # Both detail code paths: the failed one renders the error panel, the
      # ready one does not.
      @job_paths = [
        "/flightdeck/jobs/#{scenario[:failed].id}?state=failed",
        "/flightdeck/jobs/#{scenario[:ready].id}"
      ]
    end
end
