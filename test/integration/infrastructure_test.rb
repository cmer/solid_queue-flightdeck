# frozen_string_literal: true

require "test_helper"

class Flightdeck::QueuesPageTest < FlightdeckIntegrationTest
  test "requires authentication" do
    get "/flightdeck/queues"

    assert_response :unauthorized
  end

  test "shows a card per queue with depth, latency and rate" do
    create_ready_job(queue_name: "critical", created_at: 40.seconds.ago)
    create_ready_job(queue_name: "critical", created_at: 10.seconds.ago)
    create_finished_job(queue_name: "critical", finished_at: 5.minutes.ago)

    get_fd "/flightdeck/queues"

    assert_response :success
    assert_select ".fd-qcard", count: 1
    assert_select ".fd-qcard h3", text: "critical"
    assert_select ".fd-qcard .stats .v", text: "2"
    assert_select ".fd-pill.ready", text: "ACTIVE"
  end

  test "a paused queue is marked paused, with how long for, and offers resume" do
    create_ready_job(queue_name: "webhooks")
    SolidQueue::Pause.create!(queue_name: "webhooks", created_at: 42.minutes.ago)

    get_fd "/flightdeck/queues"

    assert_select ".fd-qcard.paused-card"
    assert_select ".fd-pill.paused", text: /PAUSED/
    assert_select "form[action=?]", "/flightdeck/queues/resume?name=webhooks"
  end

  test "pausing a queue goes through Solid Queue and creates the pause row" do
    create_ready_job(queue_name: "critical")

    post_fd "/flightdeck/queues/pause", params: { name: "critical" }

    assert_response :redirect
    assert SolidQueue::Queue.new("critical").paused?
    assert SolidQueue::Pause.exists?(queue_name: "critical")
    assert_match(/Paused critical/, flash[:notice].to_s)
  end

  test "resuming a queue removes the pause row" do
    create_ready_job(queue_name: "critical")
    SolidQueue::Queue.new("critical").pause

    post_fd "/flightdeck/queues/resume", params: { name: "critical" }

    refute SolidQueue::Queue.new("critical").paused?
    assert_match(/Resumed critical/, flash[:notice].to_s)
  end

  test "an unknown queue name is refused rather than creating a stray pause" do
    post_fd "/flightdeck/queues/pause", params: { name: "not-a-queue" }

    assert_equal 0, SolidQueue::Pause.count
    assert_match(/unknown queue/i, flash[:alert].to_s)
  end

  test "pausing over turbo streams answers with a toast and the refreshed cards" do
    create_ready_job(queue_name: "critical")

    post_fd "/flightdeck/queues/pause", params: { name: "critical" }, headers: turbo_stream_headers

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=append][target=fd-toasts]"
    assert_select "turbo-stream[action=replace][target=fd-queues]"
    assert_includes response.body, "Paused critical"
    assert_includes response.body, "paused-card"
  end

  test "the cards live in a polling frame" do
    create_ready_job(queue_name: "critical")

    get_fd "/flightdeck/queues"

    assert_select "turbo-frame#fd-queues[data-controller=refresh]"
  end
end

class Flightdeck::ProcessesPageTest < FlightdeckIntegrationTest
  test "requires authentication" do
    get "/flightdeck/processes"

    assert_response :unauthorized
  end

  test "groups supervisees under their supervisor and shows their configuration" do
    create_fleet

    get_fd "/flightdeck/processes"

    assert_response :success
    assert_select "table.fd-data tbody tr", count: 4
    assert_select "td.cls.fd-indent", count: 3
    assert_select "td", text: /queues: critical,default · 10 threads/
  end

  test "heartbeat freshness is rendered as an LED class" do
    threshold = SolidQueue.process_alive_threshold
    create_worker(pid: 1, last_heartbeat_at: 2.seconds.ago)
    create_worker(pid: 2, last_heartbeat_at: (threshold * 0.5).ago)
    create_worker(pid: 3, last_heartbeat_at: (threshold + 1.minute).ago)

    get_fd "/flightdeck/processes"

    assert_select ".fd-led.fresh", count: 1
    assert_select ".fd-led.stale", count: 1
    assert_select ".fd-led.dead", count: 1
  end

  test "a dead process raises a banner naming the executions it still holds" do
    dead = create_worker(pid: 5501, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)
    create_claimed_job(process: dead)

    get_fd "/flightdeck/processes"

    assert_select ".fd-alert", count: 1
    assert_select ".fd-alert", text: /1 claimed execution will be released/
    assert_select ".fd-alert a[href=?]", "/flightdeck/jobs?state=in_progress"
  end

  test "no banner when the whole fleet is healthy" do
    create_fleet

    get_fd "/flightdeck/processes"

    assert_select ".fd-alert", count: 0
  end

  test "only a dead process offers a prune button" do
    create_worker(pid: 4172)
    dead = create_worker(pid: 5501, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)

    get_fd "/flightdeck/processes"

    assert_select "form[action=?]", "/flightdeck/processes/#{dead.id}/prune"
    assert_select "form[action*=prune]", count: 1
  end

  test "pruning a dead process removes it and releases its claimed executions" do
    dead = create_worker(pid: 5501, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)
    job = create_claimed_job(process: dead)

    post_fd "/flightdeck/processes/#{dead.id}/prune"

    assert_nil SolidQueue::Process.find_by(id: dead.id), "the process row should be gone"
    refute SolidQueue::ClaimedExecution.exists?(job_id: job.id), "the claim should have been released"
    assert_match(/Pruned Worker/, flash[:notice].to_s)
    assert_match(/released 1 claimed execution/, flash[:notice].to_s)
  end

  test "a job held by a pruned process is marked failed by Solid Queue" do
    dead = create_worker(pid: 5501, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)
    job = create_claimed_job(process: dead)

    post_fd "/flightdeck/processes/#{dead.id}/prune"

    assert SolidQueue::FailedExecution.exists?(job_id: job.id),
           "Solid Queue should have failed the orphaned execution"
  end

  test "pruning a live process is refused" do
    live = create_worker(pid: 4172, last_heartbeat_at: 1.second.ago)

    post_fd "/flightdeck/processes/#{live.id}/prune"

    assert_not_nil SolidQueue::Process.find_by(id: live.id), "a healthy process must survive"
    assert_match(/still sending heartbeats/i, flash[:alert].to_s)
  end

  test "pruning a process that has already gone reports it" do
    post_fd "/flightdeck/processes/999999/prune"

    assert_match(/no longer registered/i, flash[:alert].to_s)
  end

  test "pruning over turbo streams answers with a toast and the refreshed fleet" do
    dead = create_worker(pid: 5501, last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)

    post_fd "/flightdeck/processes/#{dead.id}/prune", headers: turbo_stream_headers

    assert_response :success
    assert_select "turbo-stream[action=append][target=fd-toasts]"
    assert_select "turbo-stream[action=replace][target=fd-processes]"
  end

  test "an empty fleet says so" do
    get_fd "/flightdeck/processes"

    assert_select ".fd-empty", text: /No Solid Queue processes/
  end
end

class Flightdeck::RecurringPageTest < FlightdeckIntegrationTest
  test "requires authentication" do
    get "/flightdeck/recurring_tasks"

    assert_response :unauthorized
  end

  test "lists each task with its cron, human schedule, last and next run" do
    task = create_recurring_task(key: "daily_digest", schedule: "0 23 * * *")
    record_recurring_run(task, run_at: 30.minutes.ago)

    get_fd "/flightdeck/recurring_tasks"

    assert_response :success
    assert_select "td.cls", text: "daily_digest"
    assert_select "td.fd-cron", text: /0 23 \* \* \*/
    assert_select "td.fd-cron small", text: "every day at 23:00"
    assert_includes response.body, "30m ago"
    assert_select ".fd-pill.finished", text: "OK"
  end

  test "a task whose last run failed is flagged" do
    task = create_recurring_task(key: "reconcile", schedule: "15 */2 * * *")
    record_recurring_run(task, run_at: 10.minutes.ago, failed: true)

    get_fd "/flightdeck/recurring_tasks"

    assert_select ".fd-pill.failed", text: "LAST RUN FAILED"
    assert_select "td.fd-cron small", text: "every 2 hours at :15"
  end

  test "an unrecognised schedule shows the raw cron alone" do
    create_recurring_task(key: "odd", schedule: "0,30 9-17 * * *")

    get_fd "/flightdeck/recurring_tasks"

    assert_select "td.fd-cron", text: /0,30 9-17 \* \* \*/
    assert_select "td.fd-cron small", count: 0
  end

  test "a task that has never run says never" do
    create_recurring_task(key: "fresh")

    get_fd "/flightdeck/recurring_tasks"

    assert_select "td", text: "never"
  end

  test "run now enqueues the task's job through Solid Queue" do
    task = create_recurring_task(key: "sync", class_name: "RecurringProbeJob")

    assert_difference -> { SolidQueue::Job.where(class_name: "RecurringProbeJob").count }, 1 do
      post_fd "/flightdeck/recurring_tasks/#{task.id}/run"
    end

    assert_match(/Enqueued sync as job #\d+/, flash[:notice].to_s)
  end

  test "run now records the run against the task so the page reflects it" do
    task = create_recurring_task(key: "sync")

    post_fd "/flightdeck/recurring_tasks/#{task.id}/run"

    assert_equal 1, SolidQueue::RecurringExecution.where(task_key: "sync").count
    assert_equal :ok, Flightdeck::RecurringCatalog.new.rows.first.last_status
  end

  test "the enqueued job is ready to be picked up" do
    task = create_recurring_task(key: "sync")

    post_fd "/flightdeck/recurring_tasks/#{task.id}/run"

    job = SolidQueue::Job.find_by(class_name: "RecurringProbeJob")
    assert_not_nil job
    assert SolidQueue::ReadyExecution.exists?(job_id: job.id), "the job should have been dispatched"
  end

  test "running a task that no longer exists reports it" do
    post_fd "/flightdeck/recurring_tasks/999999/run"

    assert_match(/no longer exists/i, flash[:alert].to_s)
  end

  test "run now over turbo streams answers with a toast and the refreshed table" do
    task = create_recurring_task(key: "sync")

    post_fd "/flightdeck/recurring_tasks/#{task.id}/run", headers: turbo_stream_headers

    assert_response :success
    assert_select "turbo-stream[action=append][target=fd-toasts]"
    assert_select "turbo-stream[action=replace][target=fd-recurring]"
  end

  test "an empty schedule says so" do
    get_fd "/flightdeck/recurring_tasks"

    assert_select ".fd-empty", text: /No recurring tasks/
  end
end

class Flightdeck::InfrastructureNavigationTest < FlightdeckIntegrationTest
  test "the sidebar links to all three infrastructure pages" do
    get_fd "/flightdeck/queues"

    assert_select ".fd-nav-link[href=?]", "/flightdeck/queues"
    assert_select ".fd-nav-link[href=?]", "/flightdeck/processes"
    assert_select ".fd-nav-link[href=?]", "/flightdeck/recurring_tasks"
    assert_select ".fd-nav-link.on[href=?]", "/flightdeck/queues"
  end

  test "infrastructure actions are CSRF protected" do
    create_ready_job(queue_name: "critical")

    post_fd "/flightdeck/queues/pause", params: { name: "critical" }, csrf: false

    assert_response :unprocessable_content
    assert_equal 0, SolidQueue::Pause.count
  end
end
