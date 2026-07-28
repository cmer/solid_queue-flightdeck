# frozen_string_literal: true

require "test_helper"

class Flightdeck::RecurringCatalogTest < ActiveSupport::TestCase
  test "lists tasks by key with their schedule and job class" do
    create_recurring_task(key: "sync", schedule: "*/5 * * * *")
    create_recurring_task(key: "digest", schedule: "0 23 * * *")

    rows = Flightdeck::RecurringCatalog.new.rows

    assert_equal %w[digest sync], rows.map(&:key)
    assert_equal "RecurringProbeJob", rows.first.job_class
    assert_equal "0 23 * * *", rows.first.schedule
  end

  test "next run comes from the task's own schedule API" do
    task = create_recurring_task(key: "hourly", schedule: "0 * * * *")

    row = Flightdeck::RecurringCatalog.new.rows.first

    assert_equal task.next_time, row.next_run_at
    assert_operator row.next_run_in, :>, 0
  end

  test "a task that has never run says so" do
    create_recurring_task(key: "fresh")

    row = Flightdeck::RecurringCatalog.new.rows.first

    refute row.ever_run?
    assert_nil row.last_status
  end

  test "last run reports OK when the recorded job did not fail" do
    task = create_recurring_task(key: "sync")
    record_recurring_run(task, run_at: 10.minutes.ago)

    row = Flightdeck::RecurringCatalog.new.rows.first

    assert row.ever_run?
    assert_equal :ok, row.last_status
    assert_in_delta 10.minutes.ago, row.last_run_at, 5
  end

  test "last run reports failed when the recorded job is in failed_executions" do
    task = create_recurring_task(key: "reconcile")
    record_recurring_run(task, run_at: 10.minutes.ago, failed: true)

    row = Flightdeck::RecurringCatalog.new.rows.first

    assert_equal :failed, row.last_status
    assert row.failed?
  end

  test "only the most recent run decides the status" do
    task = create_recurring_task(key: "sync")
    record_recurring_run(task, run_at: 2.hours.ago, failed: true)
    record_recurring_run(task, run_at: 10.minutes.ago)

    assert_equal :ok, Flightdeck::RecurringCatalog.new.rows.first.last_status
  end

  test "deleting a job cascades its recurring execution away where FKs are enforced" do
    task = create_recurring_task(key: "old")
    job = record_recurring_run(task, run_at: 3.days.ago)

    job.delete

    assert_equal 0, SolidQueue::RecurringExecution.count
    refute Flightdeck::RecurringCatalog.new.rows.first.ever_run?
  end

  test "statuses do not leak between tasks" do
    ok = create_recurring_task(key: "aaa_ok")
    bad = create_recurring_task(key: "zzz_failed")
    record_recurring_run(ok, run_at: 5.minutes.ago)
    record_recurring_run(bad, run_at: 5.minutes.ago, failed: true)

    by_key = Flightdeck::RecurringCatalog.new.rows.index_by(&:key)

    assert_equal :ok, by_key["aaa_ok"].last_status
    assert_equal :failed, by_key["zzz_failed"].last_status
  end
end

# Solid Queue's own RecurringExecution.clearable scope (`where.missing(:job)`)
# exists precisely because a purged job can leave its recurring execution behind
# wherever the schema's foreign keys are not enforced — a separate queue
# database, most commonly. Reproducing that needs `PRAGMA foreign_keys = OFF`,
# which SQLite ignores inside a transaction, so this case runs without the
# surrounding test transaction. before_setup truncates the Solid Queue tables,
# so nothing leaks into the next test.
class Flightdeck::RecurringCatalogPurgedJobTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a purged job is reported as unknown rather than as a success" do
    task = create_recurring_task(key: "old")
    job = record_recurring_run(task, run_at: 3.days.ago)

    SolidQueue::Record.connection.disable_referential_integrity do
      SolidQueue::Job.where(id: job.id).delete_all
    end

    assert_nil SolidQueue::Job.find_by(id: job.id)
    assert_equal 1, SolidQueue::RecurringExecution.count, "the execution row should have survived"

    row = Flightdeck::RecurringCatalog.new.rows.first

    assert row.ever_run?
    assert_equal :unknown, row.last_status
  end
end

class Flightdeck::CronScheduleTest < ActiveSupport::TestCase
  test "describes the common cron shapes" do
    {
      "* * * * *" => "every minute",
      "*/5 * * * *" => "every 5 minutes",
      "*/15 * * * *" => "every 15 minutes",
      "0 * * * *" => "every hour at :00",
      "15 * * * *" => "every hour at :15",
      "15 */2 * * *" => "every 2 hours at :15",
      "0 23 * * *" => "every day at 23:00",
      "30 4 * * *" => "every day at 04:30",
      "0 2 * * 1" => "Mondays at 02:00",
      "0 2 * * 0" => "Sundays at 02:00",
      "0 6 1 * *" => "day 1 of every month at 06:00"
    }.each do |cron, expected|
      assert_equal expected, Flightdeck::CronSchedule.humanize(cron), "for #{cron}"
    end
  end

  test "keeps a trailing timezone" do
    assert_equal "every day at 23:00 America/Montreal",
                 Flightdeck::CronSchedule.humanize("0 23 * * * America/Montreal")
  end

  test "declines to describe shapes it does not genuinely understand" do
    [
      "0,30 * * * *",
      "0 9-17 * * *",
      "0 0 1 1 1",
      "every 5 minutes",
      "@daily",
      ""
    ].each do |cron|
      assert_nil Flightdeck::CronSchedule.humanize(cron),
                 "#{cron.inspect} should fall back to the raw cron rather than be guessed at"
    end
  end
end
