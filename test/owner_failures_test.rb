# frozen_string_literal: true

require "test_helper"

class Flightdeck::OwnerFailuresTest < ActiveSupport::TestCase
  BILLING = "Billing::ChargeSubscriptionJob"
  NOTIFICATIONS = "Notifications::PushJob"

  setup do
    @codeowners = Flightdeck::Codeowners.new("", path: Rails.root.join(".github/CODEOWNERS").to_s)
    @codeowners.define_singleton_method(:owners_for_class) do |name|
      { BILLING => %w[billing], NOTIFICATIONS => %w[growth mobile] }.fetch(name, [])
    end
  end

  test "counts each class into every window its failures fall in" do
    create_failed_job(class_name: BILLING, failed_at: 10.minutes.ago)
    create_failed_job(class_name: BILLING, failed_at: 2.hours.ago)
    create_failed_job(class_name: BILLING, failed_at: 2.days.ago)
    create_failed_job(class_name: BILLING, failed_at: 30.days.ago)

    row = report.rows.sole

    assert_equal BILLING, row.class_name
    assert_equal 4, row.total
    assert_equal [ 1, 2, 2, 3, 3 ], row.windows
  end

  test "only failed jobs count" do
    create_ready_job(class_name: BILLING)
    create_finished_job(class_name: BILLING)

    assert_empty report.rows
  end

  test "rows list the biggest failures first" do
    create_failed_job(class_name: BILLING)
    2.times { create_failed_job(class_name: NOTIFICATIONS) }

    assert_equal [ NOTIFICATIONS, BILLING ], report.rows.map(&:class_name)
  end

  test "filtering by an owner keeps the classes it shares" do
    create_failed_job(class_name: BILLING)
    create_failed_job(class_name: NOTIFICATIONS)

    assert_equal [ NOTIFICATIONS ], report(owner: "mobile").rows.map(&:class_name)
    assert_equal [ NOTIFICATIONS ], report(owner: "growth").rows.map(&:class_name)
  end

  test "classes with no owners can be filtered as Unowned" do
    create_failed_job(class_name: "NobodysJob")
    create_failed_job(class_name: BILLING)

    assert_equal [ "NobodysJob" ], report(owner: "Unowned").rows.map(&:class_name)
  end

  test "owner totals count a shared class for each owner and put Unowned last" do
    3.times { create_failed_job(class_name: "NobodysJob") }
    2.times { create_failed_job(class_name: NOTIFICATIONS) }
    create_failed_job(class_name: BILLING)

    assert_equal [ [ "growth", 2 ], [ "mobile", 2 ], [ "billing", 1 ], [ "Unowned", 3 ] ],
                 report.owner_totals.to_a
  end

  test "totals follow the owner filter and count a shared class once" do
    2.times { create_failed_job(class_name: NOTIFICATIONS) }
    create_failed_job(class_name: BILLING)

    assert_equal 3, report.total
    assert_equal 2, report(owner: "mobile").total
    assert_equal [ 2, 2, 2, 2, 2 ], report(owner: "mobile").window_totals
  end

  test "search matches any part of the class, ignoring case" do
    create_failed_job(class_name: BILLING)
    create_failed_job(class_name: NOTIFICATIONS)

    assert_equal [ BILLING ], report(q: "chargesub").rows.map(&:class_name)
    assert_equal [ NOTIFICATIONS ], report(q: "PUSH").rows.map(&:class_name)
    assert_empty report(q: "nothing").rows
  end

  test "search treats regexp and LIKE characters literally" do
    create_failed_job(class_name: BILLING)

    assert_empty report(q: "%").rows
    assert_empty report(q: "Billing.*").rows
  end

  test "search and owner filters combine" do
    create_failed_job(class_name: BILLING)
    create_failed_job(class_name: NOTIFICATIONS)

    assert_equal [ BILLING ], report(owner: "billing", q: "charge").rows.map(&:class_name)
    assert_empty report(owner: "billing", q: "push").rows
  end

  test "owner totals follow the search, keeping the selected owner listed" do
    create_failed_job(class_name: BILLING)
    create_failed_job(class_name: "NobodysJob")

    assert_equal [ [ "Unowned", 1 ] ], report(q: "nobody").owner_totals.to_a
    assert_equal [ [ "billing", 0 ], [ "Unowned", 1 ] ], report(owner: "billing", q: "nobody").owner_totals.to_a
  end

  test "counting never selects the arguments or error columns" do
    create_failed_job(class_name: BILLING)

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    report.rows
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert statements.any?
    statements.each { |sql| refute_match(/\b(arguments|error)\b/i, sql) }
  end

  private
    def report(**filters) = Flightdeck::OwnerFailures.new(@codeowners, **filters)
end
