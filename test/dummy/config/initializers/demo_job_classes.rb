# frozen_string_literal: true

# The job classes referenced by db/seeds.rb. They must really exist:
# SolidQueue::RecurringTask validates class_name resolves, and Flightdeck's
# "Run now" enqueues through the real class.
Rails.application.config.to_prepare do
  %w[
    Billing::ChargeSubscriptionJob
    Billing::ReconcilePaymentsJob
    Fraud::ScreenOrderJob
    SearchIndexJob
    SyncInventoryJob
    Notifications::PushJob
    OrderMailerJob
    WebhookDeliveryJob
    ImageVariantJob
    Reports::DailyDigestJob
    CleanupSessionsJob
    Finance::RefreshRatesJob
  ].each do |name|
    next if Object.const_defined?(name)

    parts = name.split("::")
    parent = parts[0..-2].inject(Object) do |mod, part|
      mod.const_defined?(part, false) ? mod.const_get(part) : mod.const_set(part, Module.new)
    end
    parent.const_set(parts.last, Class.new(ActiveJob::Base) do
      def perform(*)
      end
    end)
  end
end

Flightdeck.config.codeowners_path = ".github/CODEOWNERS" if Rails.env.development?
