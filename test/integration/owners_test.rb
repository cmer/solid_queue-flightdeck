# frozen_string_literal: true

require "test_helper"

class Flightdeck::OwnersTest < FlightdeckIntegrationTest
  teardown { Flightdeck.config.codeowners_path = nil }

  test "the page stays out of the nav until CODEOWNERS is configured" do
    get_fd "/flightdeck"

    assert_response :success
    assert_select "a.fd-nav-link[href='/flightdeck/owners']", 0
  end

  test "the page explains how to turn it on" do
    get_fd "/flightdeck/owners"

    assert_response :success
    assert_includes response.body, "config.codeowners_path"
  end

  test "a configured file that is missing is reported, not raised" do
    Flightdeck.config.codeowners_path = ".github/NOPE"

    get_fd "/flightdeck/owners"

    assert_response :success
    assert_includes response.body, ".github/NOPE"
  end

  test "lists classes with their owners, and links to their failed jobs" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")
    create_failed_job(class_name: "Notifications::PushJob")

    get_fd "/flightdeck"
    assert_select "a.fd-nav-link[href='/flightdeck/owners']", 1

    get_fd "/flightdeck/owners"

    assert_response :success
    assert_select "td.cls", text: "Billing::ChargeSubscriptionJob"
    assert_select "td", text: "growth, mobile"
    assert_select "a[href=?]", "/flightdeck/jobs?class_name=Billing%3A%3AChargeSubscriptionJob&state=failed"
  end

  test "filtering by owner narrows the rows and keeps the filter across polls" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")
    create_failed_job(class_name: "Notifications::PushJob")

    get_fd "/flightdeck/owners", params: { owner: "billing" }

    assert_select "td.cls", text: "Billing::ChargeSubscriptionJob"
    assert_select "td.cls", text: "Notifications::PushJob", count: 0
    assert_select "turbo-frame#fd-owners[data-refresh-url-value=?]", "/flightdeck/owners?owner=billing"
  end

  test "a malformed owner parameter finds nothing rather than failing" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")

    get_fd "/flightdeck/owners", params: { owner: { nested: "x" } }

    assert_response :success
  end

  test "class names and non-zero counts open the failed list, filtered" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob", failed_at: 2.hours.ago)

    get_fd "/flightdeck/owners"

    list = "/flightdeck/jobs?class_name=Billing%3A%3AChargeSubscriptionJob"
    assert_select "td.cls a[href=?]", "#{list}&state=failed", text: "Billing::ChargeSubscriptionJob"
    assert_select "td a[href=?]", "#{list}&failed_within=3h&state=failed", text: "1"
    assert_select "td a[href=?]", "/flightdeck/jobs?failed_within=3h&state=failed", text: "1"
    assert_select "a[href*=?]", "failed_within=1h", count: 0
  end

  test "totals stop linking when an owner is selected, since the list cannot show it" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")

    get_fd "/flightdeck/owners", params: { owner: "billing" }

    assert_select "td a[href=?]", "/flightdeck/jobs?failed_within=1h&state=failed", count: 0
  end

  test "searching narrows the rows and survives polls and owner chips" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")
    create_failed_job(class_name: "Notifications::PushJob")

    get_fd "/flightdeck/owners", params: { q: "charge" }

    assert_select "td.cls", text: "Billing::ChargeSubscriptionJob"
    assert_select "td.cls", text: "Notifications::PushJob", count: 0
    assert_select "input[type=search][name=q][value=charge]"
    assert_select "turbo-frame#fd-owners[data-refresh-url-value=?]", "/flightdeck/owners?q=charge"
    assert_select ".fd-chip[href=?]", "/flightdeck/owners?owner=billing&q=charge"
    assert_select "turbo-frame form", 0
  end

  test "searching keeps the selected owner" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")

    get_fd "/flightdeck/owners", params: { owner: "billing" }

    assert_select "form.fd-filterbar input[type=hidden][name=owner][value=billing]"
  end

  test "totals stop linking during a search, and a miss says so" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")

    get_fd "/flightdeck/owners", params: { q: "charge" }
    assert_select "td a[href=?]", "/flightdeck/jobs?failed_within=1h&state=failed", count: 0
    assert_select "td a[href*=?]", "class_name=Billing", minimum: 1

    get_fd "/flightdeck/owners", params: { q: "nothing" }
    assert_includes response.body, "No failed jobs match this search"
  end

  test "a blank search shows everything" do
    configure
    create_failed_job(class_name: "Billing::ChargeSubscriptionJob")

    get_fd "/flightdeck/owners", params: { q: "   " }

    assert_select "td.cls", text: "Billing::ChargeSubscriptionJob"
  end

  test "the panel's links escape its frame" do
    configure

    get_fd "/flightdeck/owners"

    assert_select "turbo-frame#fd-owners[target=_top]", 1
  end

  private
    def configure = Flightdeck.config.codeowners_path = ".github/CODEOWNERS"
end
