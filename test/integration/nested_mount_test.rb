# frozen_string_literal: true

require "test_helper"

# Flightdeck must work wherever it is mounted, including inside a namespace
# behind the host's own constraints:
#
#   namespace :admin do
#     mount Flightdeck::Engine, at: "/flightdeck"
#   end
#
# Nothing in the engine may assume it lives at /flightdeck — or that the mount's
# route name is `flightdeck`: a namespaced mount is named admin_flightdeck, and
# a host can pick anything with `as:`. Every URL the engine emits has to be
# derived from the current request's script_name, so the dummy app mounts the
# engine three times (plain, namespaced, renamed) and these tests drive the
# non-plain mounts.
class Flightdeck::NestedMountTest < FlightdeckIntegrationTest
  MOUNT = "/admin/flightdeck"
  OTHER_MOUNT = "/flightdeck"
  RENAMED_MOUNT = "/ops/dash"

  # Any absolute Flightdeck URL that is not under the nested mount means
  # something emitted a path from the wrong mount point.
  def assert_no_bare_mount_urls(body, context)
    stray = body.scan(%r{(?:href|src|action|content)="(#{Regexp.escape(OTHER_MOUNT)}/[^"]*)"}).flatten
    assert_empty stray, "#{context} emitted URLs from the other mount: #{stray.uniq.first(5).inspect}"
  end

  test "the dashboard renders under a nested mount" do
    create_full_scenario

    get_fd MOUNT

    assert_response :success
    assert_select ".fd-tile", count: 6
    assert_no_bare_mount_urls response.body, "the overview"
  end

  test "asset links point at the nested mount" do
    get_fd MOUNT

    css = Flightdeck::Assets.digested_name("flightdeck.css")
    js = Flightdeck::Assets.digested_name("flightdeck.js")

    assert_includes response.body, %(href="#{MOUNT}/assets/#{css}")
    assert_includes response.body, %(src="#{MOUNT}/assets/#{js}")
  end

  test "the assets themselves are served from the nested mount" do
    get "#{MOUNT}/assets/#{Flightdeck::Assets.digested_name("flightdeck.css")}"

    assert_response :success
    assert_equal "text/css", response.media_type
  end

  test "the Turbo root is the nested mount, so Turbo Drive stays inside it" do
    get_fd MOUNT

    assert_includes response.body, %(<meta name="turbo-root" content="#{MOUNT}/">)
    refute_includes response.body, %(<meta name="turbo-root" content="#{OTHER_MOUNT}/">)
  end

  test "every navigation link is prefixed with the nested mount" do
    get_fd MOUNT

    document = Nokogiri::HTML(response.body)
    links = document.css(".fd-nav-link").map { |link| link["href"] }

    assert_operator links.size, :>=, 5
    links.each do |href|
      assert href.start_with?("#{MOUNT}/"), "nav link #{href.inspect} is not under the nested mount"
    end
  end

  test "every page under the nested mount keeps its links inside it" do
    seed_everything

    %w[/ /jobs /jobs?state=failed /queues /processes /recurring_tasks].each do |path|
      get_fd "#{MOUNT}#{path}"

      assert_response :success, "#{MOUNT}#{path} did not render"
      assert_no_bare_mount_urls response.body, "#{MOUNT}#{path}"
    end
  end

  test "form actions are prefixed with the nested mount" do
    create_failed_job
    create_ready_job(queue_name: "critical")

    get_fd "#{MOUNT}/jobs?state=failed"
    Nokogiri::HTML(response.body).css("form[action]").each do |form|
      action = form["action"]
      next unless action.include?("flightdeck")

      assert action.start_with?("#{MOUNT}/"), "form action #{action.inspect} is not under the nested mount"
    end

    get_fd "#{MOUNT}/queues"
    actions = Nokogiri::HTML(response.body).css("form[action]").map { |form| form["action"] }

    assert_includes actions, "#{MOUNT}/queues/pause?name=critical"
  end

  test "pagination links stay under the nested mount" do
    10.times { create_ready_job }
    Flightdeck.config.per_page = 3

    get_fd "#{MOUNT}/jobs?state=ready"

    older = Nokogiri::HTML(response.body).css("a").map { |a| a["href"] }.find { |h| h.to_s.include?("before_id") }

    assert_not_nil older, "expected a pager link"
    assert older.start_with?("#{MOUNT}/jobs"), "pager link #{older.inspect} escaped the nested mount"
  ensure
    Flightdeck.config.per_page = 25
  end

  test "polling frames refresh a URL under the nested mount" do
    create_ready_job

    get_fd "#{MOUNT}/jobs?state=ready"

    Nokogiri::HTML(response.body).css("turbo-frame[data-refresh-url-value]").each do |frame|
      url = frame["data-refresh-url-value"]
      assert url.start_with?("#{MOUNT}/"), "frame #{frame["id"]} would poll #{url.inspect}"
    end
  end

  test "a job link under the nested mount points at the nested detail page" do
    job = create_ready_job(class_name: "AlphaJob")

    get_fd "#{MOUNT}/jobs?state=ready"

    assert_select "td.cls a[href=?]", "#{MOUNT}/jobs/#{job.id}?state=ready"

    get_fd "#{MOUNT}/jobs/#{job.id}"
    assert_response :success
    assert_select ".fd-jd-head h2", text: "AlphaJob"
  end

  # --- actions --------------------------------------------------------------

  test "a POST under the nested mount works and redirects back into it" do
    create_ready_job(queue_name: "critical")

    post_fd "#{MOUNT}/queues/pause", params: { name: "critical" }

    assert_redirected_to "#{MOUNT}/queues"
    assert SolidQueue::Queue.new("critical").paused?
  end

  test "a turbo-stream action under the nested mount renders nested URLs" do
    job = create_failed_job

    post_fd "#{MOUNT}/jobs/#{job.id}/retry",
            params: { state: "failed" },
            headers: turbo_stream_headers

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=replace][target=fd-jobs]"
    assert_no_bare_mount_urls response.body, "the retry turbo-stream"
    assert SolidQueue::ReadyExecution.exists?(job_id: job.id)
  end

  test "the range control under the nested mount stays nested" do
    get_fd "#{MOUNT}?range=1h"

    assert_response :success
    assert_select ".fd-seg a[href^=?]", "#{MOUNT}/"
    assert_no_bare_mount_urls response.body, "the range control"
  end

  # --- a mount with a custom route name (as: :renamed) ----------------------

  test "the dashboard renders under a mount with a custom route name" do
    create_full_scenario

    get_fd RENAMED_MOUNT

    assert_response :success
    assert_select ".fd-tile", count: 6
    assert_includes response.body, %(<meta name="turbo-root" content="#{RENAMED_MOUNT}/">)
  end

  test "every URL under the renamed mount stays inside it" do
    create_failed_job

    get_fd RENAMED_MOUNT

    document = Nokogiri::HTML(response.body)
    links = document.css(".fd-nav-link").map { |link| link["href"] }

    assert_operator links.size, :>=, 5
    links.each do |href|
      assert href.start_with?("#{RENAMED_MOUNT}/"), "nav link #{href.inspect} is not under the renamed mount"
    end

    stray = response.body.scan(%r{(?:href|src|action|content)="(/(?:admin/)?flightdeck/[^"]*)"}).flatten
    assert_empty stray, "the renamed mount emitted URLs from another mount: #{stray.uniq.first(5).inspect}"
  end

  test "asset links point at the renamed mount" do
    get_fd RENAMED_MOUNT

    css = Flightdeck::Assets.digested_name("flightdeck.css")

    assert_includes response.body, %(href="#{RENAMED_MOUNT}/assets/#{css}")
  end

  # --- both mounts coexist --------------------------------------------------

  test "the original mount is unaffected by the nested one" do
    create_full_scenario

    get_fd OTHER_MOUNT

    assert_response :success
    assert_includes response.body, %(<meta name="turbo-root" content="#{OTHER_MOUNT}/">)

    stray = response.body.scan(%r{(?:href|src|action)="(#{Regexp.escape(MOUNT)}/[^"]*)"}).flatten
    assert_empty stray, "the top-level mount emitted nested-mount URLs: #{stray.uniq.first(5).inspect}"
  end

  test "authentication applies to the nested mount too" do
    get MOUNT

    assert_response :unauthorized
    assert_match(/Basic realm="Flightdeck"/, response.headers["WWW-Authenticate"])
  end

  test "assets under the nested mount are still served without authentication" do
    get "#{MOUNT}/assets/#{Flightdeck::Assets.digested_name("flightdeck.js")}"

    assert_response :success
  end

  private
    def seed_everything
      create_full_scenario
      create_fleet
      task = create_recurring_task(key: "digest")
      record_recurring_run(task, run_at: 1.hour.ago)
      create_finished_job(queue_name: "critical", finished_at: 30.minutes.ago)
    end
end
