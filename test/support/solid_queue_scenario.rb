# frozen_string_literal: true

# Builds Solid Queue rows directly, in every state a job can be in.
#
# Nothing here starts a worker, a dispatcher or a supervisor: the tests are
# about how Flightdeck reads and mutates the tables, and real processes would
# make them slow and racy. Rows are created through Solid Queue's own models so
# they carry exactly the columns and defaults production would have.
module SolidQueueScenario
  DEFAULT_ARGUMENTS = {
    "job_class" => "TestJob",
    "job_id" => nil,
    "queue_name" => "default",
    "arguments" => [ { "id" => 1 } ],
    "executions" => 0
  }.freeze

  def clear_solid_queue!
    if defined?(SolidQueue::BatchExecution) && SolidQueue::BatchExecution.table_exists?
      SolidQueue::BatchExecution.delete_all
    end
    if defined?(SolidQueue::Batch) && SolidQueue::Batch.table_exists?
      SolidQueue::Batch.delete_all
    end
    SolidQueue::ClaimedExecution.delete_all
    SolidQueue::ReadyExecution.delete_all
    SolidQueue::ScheduledExecution.delete_all
    SolidQueue::BlockedExecution.delete_all
    SolidQueue::FailedExecution.delete_all
    SolidQueue::Semaphore.delete_all
    SolidQueue::RecurringExecution.delete_all
    SolidQueue::RecurringTask.delete_all
    SolidQueue::Pause.delete_all
    SolidQueue::Job.delete_all
    SolidQueue::Process.delete_all
  end

  # --- infrastructure -------------------------------------------------------

  def pause_queue(name)
    SolidQueue::Queue.new(name).pause
  end

  def create_supervisor(hostname: "jobs-01", pid: 4102, **attributes)
    create_process(kind: "Supervisor", hostname: hostname, pid: pid, **attributes)
  end

  def create_worker(supervisor: nil, hostname: "jobs-01", pid: 4172,
                    queues: "critical,default", threads: 10, **attributes)
    create_process(
      kind: "Worker", hostname: hostname, pid: pid, supervisor: supervisor,
      metadata: { "queues" => queues, "thread_pool_size" => threads, "polling_interval" => 0.1 },
      **attributes
    )
  end

  def create_dispatcher(supervisor: nil, hostname: "jobs-01", pid: 4174, **attributes)
    create_process(
      kind: "Dispatcher", hostname: hostname, pid: pid, supervisor: supervisor,
      metadata: { "batch_size" => 500, "polling_interval" => 1 },
      **attributes
    )
  end

  def create_scheduler(supervisor: nil, hostname: "jobs-01", pid: 4175, task_keys: %w[digest sync], **attributes)
    create_process(
      kind: "Scheduler", hostname: hostname, pid: pid, supervisor: supervisor,
      metadata: { "recurring_schedule" => task_keys },
      **attributes
    )
  end

  # A supervisor with a worker, dispatcher and scheduler beneath it.
  def create_fleet(hostname: "jobs-01", heartbeat: Time.current, task_keys: %w[digest sync])
    supervisor = create_supervisor(hostname: hostname, last_heartbeat_at: heartbeat)
    {
      supervisor: supervisor,
      worker: create_worker(supervisor: supervisor, hostname: hostname, last_heartbeat_at: heartbeat),
      dispatcher: create_dispatcher(supervisor: supervisor, hostname: hostname, last_heartbeat_at: heartbeat),
      scheduler: create_scheduler(supervisor: supervisor, hostname: hostname,
                                  task_keys: task_keys, last_heartbeat_at: heartbeat)
    }
  end

  # --- recurring ------------------------------------------------------------

  def create_recurring_task(key: "digest", schedule: "0 23 * * *",
                            class_name: "RecurringProbeJob", **attributes)
    SolidQueue::RecurringTask.create!(
      key: key, schedule: schedule, class_name: class_name, static: true, **attributes
    )
  end

  # Records a past run of a task against a job, so last-run status has something
  # real to read.
  def record_recurring_run(task, run_at: 1.hour.ago, job: nil, failed: false)
    job ||= failed ? create_failed_job(class_name: task.class_name) : create_finished_job(class_name: task.class_name)

    SolidQueue::RecurringExecution.create!(job_id: job.id, task_key: task.key, run_at: run_at)
    job
  end

  # Creates the jobs row only. `after_create :prepare_for_execution` would
  # immediately dispatch it, so scenarios that want a specific state insert the
  # execution row themselves — hence insert_all rather than create!.
  def create_job(class_name: "TestJob", queue_name: "default", priority: 0,
                 scheduled_at: nil, finished_at: nil, concurrency_key: nil,
                 arguments: nil, created_at: Time.current, executions: 0)
    active_job_id = SecureRandom.uuid
    payload = (arguments || DEFAULT_ARGUMENTS).merge(
      "job_class" => class_name,
      "job_id" => active_job_id,
      "queue_name" => queue_name,
      "executions" => executions
    )

    SolidQueue::Job.insert_all!([ {
      queue_name: queue_name,
      class_name: class_name,
      arguments: payload,
      priority: priority,
      active_job_id: active_job_id,
      scheduled_at: scheduled_at,
      finished_at: finished_at,
      concurrency_key: concurrency_key,
      created_at: created_at,
      updated_at: created_at
    } ])

    SolidQueue::Job.order(id: :desc).first
  end

  # The ready row defaults to the job's own created_at, which is what a job
  # dispatched at enqueue time looks like — and what queue latency measures.
  def create_ready_job(ready_at: nil, **attributes)
    create_job(**attributes).tap do |job|
      SolidQueue::ReadyExecution.insert_all!([
        { job_id: job.id, queue_name: job.queue_name, priority: job.priority,
          created_at: ready_at || job.created_at }
      ])
    end
  end

  def create_scheduled_job(scheduled_at: 1.hour.from_now, **attributes)
    create_job(scheduled_at: scheduled_at, **attributes).tap do |job|
      SolidQueue::ScheduledExecution.insert_all!([
        { job_id: job.id, queue_name: job.queue_name, priority: job.priority,
          scheduled_at: scheduled_at, created_at: Time.current }
      ])
    end
  end

  def create_claimed_job(process: nil, **attributes)
    process ||= create_process
    create_job(**attributes).tap do |job|
      SolidQueue::ClaimedExecution.insert_all!([
        { job_id: job.id, process_id: process.id, created_at: Time.current }
      ])
    end
  end

  def create_blocked_job(concurrency_key: "widgets/1", **attributes)
    create_job(concurrency_key: concurrency_key, **attributes).tap do |job|
      SolidQueue::BlockedExecution.insert_all!([
        { job_id: job.id, queue_name: job.queue_name, priority: job.priority,
          concurrency_key: concurrency_key, expires_at: 5.minutes.from_now, created_at: Time.current }
      ])
    end
  end

  def create_failed_job(exception_class: "Stripe::RateLimitError",
                        message: "Too many requests hit the API too quickly.",
                        backtrace: nil, failed_at: nil, **attributes)
    backtrace ||= [
      "gems/stripe-12.1.0/lib/stripe/api_requestor.rb:412:in `handle_error_response'",
      "app/services/billing/charger.rb:37:in `charge!'",
      "app/jobs/billing/charge_subscription_job.rb:14:in `perform'",
      "gems/activejob-8.0.2/lib/active_job/execution.rb:68:in `block in _perform_job'"
    ]

    create_job(**attributes).tap do |job|
      SolidQueue::FailedExecution.insert_all!([ {
        job_id: job.id,
        error: { "exception_class" => exception_class, "message" => message, "backtrace" => backtrace },
        created_at: failed_at || Time.current
      } ])
    end
  end

  def create_finished_job(finished_at: 1.minute.ago, **attributes)
    create_job(finished_at: finished_at, **attributes)
  end

  def create_process(name: nil, kind: "Worker", hostname: "jobs-01", pid: 4172,
                     supervisor: nil, metadata: nil, last_heartbeat_at: Time.current)
    SolidQueue::Process.create!(
      name: name || "#{kind.downcase}-#{SecureRandom.hex(3)}",
      kind: kind,
      hostname: hostname,
      pid: pid,
      supervisor_id: supervisor&.id,
      metadata: metadata,
      last_heartbeat_at: last_heartbeat_at
    )
  end

  # --- batches --------------------------------------------------------------

  def create_batch(description: "Nightly import", total_jobs: 0, completed_jobs: 0, failed_jobs: 0,
                   enqueued_at: Time.current, finished_at: nil, failed_at: nil,
                   metadata: nil, on_finish: nil, on_success: nil, on_failure: nil,
                   created_at: Time.current)
    attrs = {
      active_job_batch_id: SecureRandom.uuid,
      description: description,
      total_jobs: total_jobs,
      completed_jobs: completed_jobs,
      failed_jobs: failed_jobs,
      enqueued_at: enqueued_at,
      finished_at: finished_at,
      failed_at: failed_at,
      created_at: created_at,
      updated_at: created_at
    }
    attrs[:metadata] = metadata if metadata
    attrs[:on_finish] = on_finish if on_finish
    attrs[:on_success] = on_success if on_success
    attrs[:on_failure] = on_failure if on_failure

    SolidQueue::Batch.insert_all!([ attrs ])
    SolidQueue::Batch.order(id: :desc).first
  end

  # Membership is the jobs.batch_id column. A pending tracking row is only
  # present while the job is still outstanding — finished and failed jobs
  # drop theirs, matching Solid Queue.
  def add_to_batch(batch, job, pending: false)
    SolidQueue::Job.where(id: job.id).update_all(batch_id: batch.id)
    if pending
      SolidQueue::BatchExecution.insert_all!([
        { job_id: job.id, batch_id: batch.id, created_at: Time.current }
      ])
    end
    job
  end

  def create_finished_batch(description: "Completed import", job_count: 2, **attributes)
    batch = create_batch(description: description, total_jobs: job_count,
                         completed_jobs: job_count, failed_jobs: 0,
                         enqueued_at: 1.hour.ago, finished_at: 50.minutes.ago, **attributes)
    job_count.times { add_to_batch(batch, create_finished_job(class_name: "ImportRowJob")) }
    batch
  end

  def create_failed_batch(description: "Failed import", **attributes)
    batch = create_batch(description: description, total_jobs: 2, completed_jobs: 1, failed_jobs: 1,
                         enqueued_at: 1.hour.ago, finished_at: 50.minutes.ago,
                         failed_at: 50.minutes.ago, **attributes)
    add_to_batch(batch, create_finished_job(class_name: "ImportRowJob"))
    add_to_batch(batch, create_failed_job(class_name: "ImportRowJob"))
    batch
  end

  # One job in every state, keyed by state name.
  def create_full_scenario
    {
      ready: create_ready_job(class_name: "WebhookDeliveryJob", queue_name: "webhooks"),
      scheduled: create_scheduled_job(class_name: "Reports::DailyDigestJob", queue_name: "low"),
      in_progress: create_claimed_job(class_name: "Fraud::ScreenOrderJob", queue_name: "critical"),
      blocked: create_blocked_job(class_name: "SyncInventoryJob", queue_name: "default"),
      failed: create_failed_job(class_name: "Billing::ChargeSubscriptionJob", queue_name: "critical"),
      finished: create_finished_job(class_name: "ImageVariantJob", queue_name: "low")
    }
  end

  def job_state(job)
    Flightdeck::JobRow.annotate([ job.id ]).dig(job.id, :state) ||
      (SolidQueue::Job.find_by(id: job.id)&.finished_at ? :finished : nil)
  end

  def in_table?(model, job)
    model.exists?(job_id: job.id)
  end
end
