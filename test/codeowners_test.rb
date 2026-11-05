# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Flightdeck::CodeownersTest < ActiveSupport::TestCase
  test "the last matching rule wins" do
    owners = codeowners(<<~TEXT)
      *                 @acme/everyone
      /app/jobs/        @acme/jobs
      /app/jobs/billing @acme/billing
    TEXT

    assert_equal %w[billing], owners.owners_for_path("app/jobs/billing/charge_job.rb")
    assert_equal %w[jobs], owners.owners_for_path("app/jobs/sync_job.rb")
    assert_equal %w[everyone], owners.owners_for_path("lib/thing.rb")
  end

  test "a later rule with no owners leaves the path unowned" do
    owners = codeowners(<<~TEXT)
      /app/ @acme/app
      /app/jobs/legacy/
    TEXT

    assert_empty owners.owners_for_path("app/jobs/legacy/old_job.rb")
  end

  test "a pattern without a leading or inner slash matches at any depth" do
    owners = codeowners("jobs/ @a\n*.rake @b\n")

    assert_equal %w[a], owners.owners_for_path("components/sales/app/jobs/report_job.rb")
    assert_equal %w[b], owners.owners_for_path("lib/tasks/seed.rake")
  end

  test "a pattern with an inner slash is anchored to the root" do
    owners = codeowners("app/jobs @a\n")

    assert_equal %w[a], owners.owners_for_path("app/jobs/thing_job.rb")
    assert_empty owners.owners_for_path("components/sales/app/jobs/thing_job.rb")
  end

  test "dir/* covers direct children only" do
    owners = codeowners("/app/jobs/* @a\n")

    assert_equal %w[a], owners.owners_for_path("app/jobs/thing_job.rb")
    assert_empty owners.owners_for_path("app/jobs/billing/thing_job.rb")
  end

  test "double stars cross directories and single stars do not" do
    owners = codeowners("**/billing/*_job.rb @a\ncomponents/**/report.rb @b\n/app/j?bs/one_*.rb @c\n")

    assert_equal %w[a], owners.owners_for_path("billing/charge_job.rb")
    assert_equal %w[a], owners.owners_for_path("components/sales/billing/charge_job.rb")
    assert_empty owners.owners_for_path("billing/nested/charge_job.rb")
    assert_equal %w[b], owners.owners_for_path("components/a/b/report.rb")
    assert_equal %w[c], owners.owners_for_path("app/jobs/one_x.rb")
  end

  test "patterns are matched literally apart from their wildcards" do
    owners = codeowners("/app/a+b.c/ @a\n")

    assert_equal %w[a], owners.owners_for_path("app/a+b.c/job.rb")
    assert_empty owners.owners_for_path("app/aab-c/job.rb")
  end

  test "comments, blank lines and escaped spaces are understood" do
    owners = codeowners(<<~'TEXT')
      # a comment

      /my\ dir/ @a # who to ask
    TEXT

    assert_equal %w[a], owners.owners_for_path("my dir/job.rb")
  end

  test "an escaped hash is not a pattern, as on GitHub" do
    owners = codeowners("* @default
\\#hash/ @b
")

    assert_equal %w[default], owners.owners_for_path("#hash/job.rb")
  end

  test "double stars inside a segment do not cross directories" do
    owners = codeowners("* @default
/app/jobs/bill**_job.rb @b
")

    assert_equal %w[b], owners.owners_for_path("app/jobs/billing_job.rb")
    assert_equal %w[default], owners.owners_for_path("app/jobs/billing/nested_job.rb")
  end

  test "a trailing double star covers everything below" do
    owners = codeowners("* @default
/components/** @b
")

    assert_equal %w[b], owners.owners_for_path("components/sales/app/job.rb")
    assert_equal %w[default], owners.owners_for_path("lib/job.rb")
  end

  test "escaped wildcards are literal" do
    owners = codeowners("* @default
/app/jobs/\\*.rb @b
/app/w\\?t.rb @c
")

    assert_equal %w[default], owners.owners_for_path("app/jobs/charge.rb")
    assert_equal %w[b], owners.owners_for_path("app/jobs/*.rb")
    assert_equal %w[default], owners.owners_for_path("app/wat.rb")
    assert_equal %w[c], owners.owners_for_path("app/w?t.rb")
  end

  test "a stray trailing backslash is literal rather than an error" do
    assert_empty codeowners("* @default\napp\\\n").owners_for_path("app\\")
  end

  test "owners read without their org, and emails stay whole" do
    assert_equal %w[billing alice ops@acme.test],
                 codeowners("* @acme/billing @alice ops@acme.test\n").owners_for_path("a.rb")
  end

  test "a job class resolves through the file that defines it" do
    with_codeowners do |owners|
      assert_equal %w[billing], owners.owners_for_class("Billing::ChargeSubscriptionJob")
      assert_equal %w[growth mobile], owners.owners_for_class("Notifications::PushJob")
    end
  end

  test "the sample CODEOWNERS gives overlapping and overriding owners" do
    with_codeowners do |owners|
      assert_equal %w[billing finance], owners.owners_for_class("Billing::SyncInvoicesJob")
      assert_equal %w[finance analytics], owners.owners_for_class("Finance::ExportReportJob")
      assert_equal %w[sales analytics], owners.owners_for_class("Sales::ExportReportJob")
      assert_equal %w[security alice], owners.owners_for_class("Security::RotateKeysJob")
      assert_equal %w[platform], owners.owners_for_class("Legacy::ExportCsvJob")
      assert_empty owners.owners_for_class("Legacy::ImportCsvJob")
    end
  end

  test "a class that is gone, or outside the repo, has no owners" do
    with_codeowners do |owners|
      assert_empty owners.owners_for_class("Gone::SinceDeployedJob")
      assert_empty owners.owners_for_class("not a constant")
      assert_empty owners.owners_for_class("ActionMailer::MailDeliveryJob")
    end
  end

  test "a class that fails to load has no owners and does not raise" do
    with_codeowners do |owners|
      broken = Class.new { def safe_constantize = raise(SyntaxError, "boom") }.new

      assert_empty owners.owners_for_class(broken)
    end
  end

  test "patterns are relative to the repo root when the file sits in .github or docs" do
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      [ ".github", "docs" ].each do |nested|
        owners = Flightdeck::Codeowners.new("", path: File.join(dir, nested, "CODEOWNERS"))
        assert_equal dir, owners.send(:root)
      end

      assert_equal dir, Flightdeck::Codeowners.new("", path: File.join(dir, "CODEOWNERS")).send(:root)
    end
  end

  test "current is nil when unconfigured or the file is missing" do
    assert_nil Flightdeck::Codeowners.current

    with_codeowners(".github/NOPE") { assert_nil Flightdeck::Codeowners.current }
  end

  test "current re-parses only when the file changes" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CODEOWNERS")
      File.write(path, "* @a\n")

      with_codeowners(path) do
        first = Flightdeck::Codeowners.current
        assert_same first, Flightdeck::Codeowners.current

        File.write(path, "* @b\n")
        File.utime(Time.now, Time.now + 10, path)
        assert_equal %w[b], Flightdeck::Codeowners.current.owners_for_path("a.rb")
      end
    end
  end

  private
  private
    def codeowners(source) = Flightdeck::Codeowners.new(source)

    def with_codeowners(path = ".github/CODEOWNERS")
      Flightdeck.config.codeowners_path = path
      yield Flightdeck::Codeowners.current
    ensure
      Flightdeck.config.codeowners_path = nil
    end
end
