# frozen_string_literal: true

if ENV["FLIGHTDECK_TEST_NAMESPACED_MOUNT"].present?
  # The real-world shape that broke referencing engine routes through the
  # host's mounted-route proxy: the only mount lives inside a namespace, so its
  # route name is admin_flightdeck and no `flightdeck` proxy method exists
  # anywhere in the process (see test/boot_test.rb). The host also claims
  # `jobs_path` for itself — the engine's own helper must still win inside
  # engine views.
  Rails.application.routes.draw do
    namespace :admin do
      mount Flightdeck::Engine, at: "/jobs"
    end

    get "host-jobs", to: proc { [ 200, { "Content-Type" => "text/plain" }, [ "host" ] ] }, as: :jobs
  end
else
  Rails.application.routes.draw do
    root to: redirect("/flightdeck")

    mount Flightdeck::Engine => "/flightdeck"

    # A second mount, deeper in the path and inside a namespace so its route
    # name is the scope-derived admin_flightdeck, proves the engine is entirely
    # mount-relative — every link, form action, asset URL and Turbo root has to
    # come from the request's own script_name rather than from a remembered
    # mount point or a hardcoded route-proxy name.
    namespace :admin do
      mount Flightdeck::Engine, at: "/flightdeck"
    end

    # A third mount whose route name and path share nothing with "flightdeck":
    # Rails' script-name merging can collapse a duplicated path tail and mask a
    # wrong-mount URL, so this one cannot pass by coincidence.
    mount Flightdeck::Engine => "/ops/dash", as: :renamed

    get "up", to: proc { [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] }
  end
end
