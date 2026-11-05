# frozen_string_literal: true

# Fills the dummy app with a realistic spread of Solid Queue state so the
# dashboard can be exercised by hand: every job state, several queues (one
# paused), two fleets (one degraded), recurring tasks, and 48 hours of
# finished/failed history so the charts and the vs-prior-24h delta have
# something to say.
#
#   cd test/dummy && bin/rails db:seed
#
# Idempotent: it clears all Solid Queue tables first.

require_relative "../../support/solid_queue_scenario"

class FlightdeckSeeder
  include SolidQueueScenario

  JOB_CLASSES = {
    "critical" => %w[Billing::ChargeSubscriptionJob Fraud::ScreenOrderJob],
    "default"  => %w[SearchIndexJob SyncInventoryJob],
    "mailers"  => %w[Notifications::PushJob OrderMailerJob],
    "webhooks" => %w[WebhookDeliveryJob],
    "low"      => %w[ImageVariantJob Reports::DailyDigestJob CleanupSessionsJob]
  }.freeze

  # Named to overlap on the Owners page: `Sync`, `Export` and `Report` cut across
  # teams, and test/dummy/.github/CODEOWNERS gives many of these two owners.
  OWNED_FAILURES = %w[
    Billing::SyncInvoicesJob Billing::RefundOrderJob
    Finance::SyncLedgerJob Finance::ExportReportJob
    Sales::SyncLeadsJob Sales::ExportReportJob Sales::SendQuoteEmailJob
    Notifications::PushJob Notifications::SendEmailJob Notifications::SendSmsJob
    Mobile::SyncDevicesJob
    Platform::SyncUsersJob Platform::ExportAuditLogJob
    Security::RotateKeysJob Security::ScanUploadsJob
    Legacy::ImportCsvJob Legacy::ExportCsvJob
  ].freeze

  RECURRING_TASKS = {
    "daily_digest"           => [ "0 23 * * *", "Reports::DailyDigestJob" ],
    "sync_inventory"         => [ "*/5 * * * *", "SyncInventoryJob" ],
    "reconcile_payments"     => [ "15 */2 * * *", "Billing::ReconcilePaymentsJob" ],
    "prune_sessions"         => [ "30 4 * * *", "CleanupSessionsJob" ],
    "refresh_exchange_rates" => [ "0 * * * *", "Finance::RefreshRatesJob" ]
  }.freeze

  ERRORS = [
    [ "Stripe::RateLimitError", "Too many requests hit the API too quickly. Request rate limit exceeded (429)." ],
    [ "Net::ReadTimeout", "Net::ReadTimeout with #<TCPSocket:(closed)> — hooks.partner.io:443" ],
    [ "Elastic::TransportError", "[503] {\"error\":\"circuit_breaking_exception\"}" ],
    [ "ActiveStorage::FileNotFoundError", "ActiveStorage::FileNotFoundError" ]
  ].freeze

  def call
    srand(42)
    clear_solid_queue!

    seed_fleet
    seed_history
    seed_owned_failures
    seed_backlog
    seed_recurring

    puts "Seeded: #{SolidQueue::Job.count} jobs, #{SolidQueue::FailedExecution.count} failed, " \
         "#{SolidQueue::ReadyExecution.count} ready, #{SolidQueue::Process.count} processes, " \
         "#{SolidQueue::RecurringTask.count} recurring tasks."
  end

  private
    def sample_class(queue) = JOB_CLASSES.fetch(queue).sample
    def queues = JOB_CLASSES.keys

    def seed_fleet
      # The scheduler advertises the recurring tasks that actually exist.
      @fleet_one = create_fleet(hostname: "jobs-01", task_keys: RECURRING_TASKS.keys)
      @extra_worker = create_worker(supervisor: @fleet_one[:supervisor], hostname: "jobs-01",
                                    pid: 4173, queues: "*", threads: 10)

      supervisor_two = create_supervisor(hostname: "jobs-02", pid: 5480)
      @dead_worker = create_worker(supervisor: supervisor_two, hostname: "jobs-02", pid: 5501,
                                   queues: "*", threads: 8, last_heartbeat_at: 8.minutes.ago)
      create_dispatcher(supervisor: supervisor_two, hostname: "jobs-02", pid: 5502)

      @stale_worker = create_worker(hostname: "web-01", pid: 1290, queues: "mailers",
                                    threads: 6, last_heartbeat_at: 2.minutes.ago)
    end

    # 48 hours of finished work with a day/night curve, plus failures with a
    # spike a few hours ago — enough for both chart windows and the tile delta.
    def seed_history
      48.times do |hours_ago|
        curve = 0.55 + 0.45 * Math.sin((hours_ago - 4) / 24.0 * Math::PI * 2)
        (2 + (10 * curve).round + rand(3)).times do
          queue = queues.sample
          enqueued = hours_ago.hours.ago - rand(3600)
          create_finished_job(
            class_name: sample_class(queue), queue_name: queue,
            created_at: enqueued, finished_at: enqueued + rand(1.0..30.0)
          )
        end

        failures = hours_ago.between?(2, 4) ? 4 + rand(3) : (rand < 0.4 ? 1 : 0)
        failures.times do
          queue = %w[critical webhooks default].sample
          exception_class, message = ERRORS.sample
          enqueued = hours_ago.hours.ago - rand(3600)
          create_failed_job(
            class_name: sample_class(queue), queue_name: queue,
            exception_class: exception_class, message: message,
            created_at: enqueued, failed_at: enqueued + rand(2.0..90.0), executions: rand(1..5)
          )
        end
      end
    end

    # One failure per Owners window, then a few at random, so every column of
    # every class has a number to click.
    def seed_owned_failures
      OWNED_FAILURES.each do |class_name|
        ages = [ 30.minutes, 2.hours, 12.hours, 2.days, 5.days ] + Array.new(rand(4)) { rand(1.hour..6.days) }

        ages.each do |age|
          exception_class, message = ERRORS.sample
          create_failed_job(
            class_name: class_name, queue_name: "default",
            exception_class: exception_class, message: message,
            created_at: age.ago - 60, failed_at: age.ago, executions: rand(1..5)
          )
        end
      end
    end

    def seed_backlog
      pause_queue("webhooks")

      { "critical" => 8, "default" => 25, "mailers" => 5, "low" => 4 }.each do |queue, count|
        count.times do
          create_ready_job(class_name: sample_class(queue), queue_name: queue,
                           created_at: rand(60).seconds.ago)
        end
      end
      12.times { create_ready_job(class_name: "WebhookDeliveryJob", queue_name: "webhooks", created_at: 42.minutes.ago + rand(300)) }

      10.times do
        create_scheduled_job(class_name: "Reports::DailyDigestJob", queue_name: "low",
                             scheduled_at: rand(1..18).hours.from_now)
      end
      create_scheduled_job(class_name: "SyncInventoryJob", queue_name: "default", scheduled_at: 40.seconds.from_now)

      [ @fleet_one[:worker], @extra_worker, @stale_worker ].each do |process|
        rand(3..6).times do
          queue = queues.sample
          create_claimed_job(class_name: sample_class(queue), queue_name: queue, process: process)
        end
      end
      3.times { create_claimed_job(class_name: "WebhookDeliveryJob", queue_name: "webhooks", process: @dead_worker) }

      4.times do |i|
        create_blocked_job(class_name: "SyncInventoryJob", queue_name: "default",
                           concurrency_key: "warehouse/yul-#{i % 2 + 1}")
      end
    end

    def seed_recurring
      RECURRING_TASKS.each do |key, (schedule, class_name)|
        task = create_recurring_task(key: key, schedule: schedule, class_name: class_name)
        record_recurring_run(task, run_at: rand(1..90).minutes.ago, failed: key == "reconcile_payments")
      end
    end
end

FlightdeckSeeder.new.call
