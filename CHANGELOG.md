# Changelog

All notable changes to Flightdeck are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The interface font is now configurable: pick one at the bottom of the sidebar
  (remembered per browser), or set the default for everyone with
  `config.ui_font`. Public Sans (the new default), Barlow, General Sans, Inter,
  Manrope, or the OS UI font.

### Changed

- Fonts are served as separate cached assets instead of being inlined in the
  stylesheet, so a browser downloads only the face it renders in. The stylesheet
  is 74% smaller (118KB → 31KB).

## [1.0.0] - 2026-08-11

### Changed

- Flightdeck is now 1.0: no functional changes from 0.6.0, but the mount point,
  `Flightdeck.configure` options and `base_controller_class` contract are now
  stable and covered by semantic versioning.

## [0.6.0] - 2026-07-28

### Changed

- The gem is now named `solid_queue-flightdeck` (previously `flightdeck`).
  Update your Gemfile line to `gem "solid_queue-flightdeck"` — the Ruby
  namespace, mount point and configuration are unchanged. The old gem name
  remains as a shell that depends on this one.

## [0.5.3] - 2026-07-28

### Fixed

- The failed-jobs selection bar's "apply to all N matching" button always
  retried, even when you meant to discard. It is now two explicit buttons,
  "Retry all" and "Discard all".

## [0.5.2] - 2026-07-27

### Fixed

- The dashboard no longer 500s when the engine is mounted under a named scope
  or namespace (e.g. `namespace :admin { mount Flightdeck::Engine, at: "/jobs" }`)
  or with a custom route name via `as:`.

## [0.5.1] - 2026-07-27

### Added

- `config.skip_authentication` to serve the dashboard without any
  authentication, for mounts guarded upstream (routing constraint, VPN, proxy).

## [0.5.0] - 2026-07-27

First release.

### Added

- Mountable Rails engine (`mount Flightdeck::Engine => "/flightdeck"`) with no
  migrations and no asset pipeline requirements.
- **Overview**: six stat tiles (24h throughput with prior-window delta, failures
  with failure rate, ready, scheduled with next-due countdown, in progress with
  worker capacity, oldest ready age), throughput and time-to-completion charts
  with 1H/24H/7D ranges, queue mini-table with sparklines, recent failures, and
  a fleet health strip.
- **Jobs**: state tabs (all, ready, scheduled, in progress, blocked, finished,
  failed) with counts, class and queue filters, prefix search, and keyset
  pagination.
- **Job detail**: error with app-frame-highlighted backtrace, pretty-printed raw
  arguments (never ActiveJob-deserialized), metadata and a derived lifecycle
  timeline.
- **Failed jobs**: grouped by exception class, row selection, and retry/discard
  for one job, the selected jobs, or everything matching the current filter —
  capped, deadlined and committed per batch.
- **Queues**: depth, latency, hourly rate and sparkline per queue, with
  pause/resume.
- **Processes**: supervisor-grouped fleet with heartbeat freshness, a
  dead-process banner, and guarded pruning.
- **Recurring tasks**: cron with a human-readable schedule, last and next run,
  last-run status, and run-now.
- Server-rendered SVG charts with no JavaScript charting library, coloured
  entirely from CSS custom properties.
- Light and dark themes from `prefers-color-scheme` with a persisted override.
- Live polling via Turbo Frames with a topbar LIVE switch, visibility-aware
  pausing, focused-input pausing and ±10% jitter.
- API-only host support via engine-local cookie, session and flash middleware.
- Authentication required in every environment: HTTP Basic from configuration,
  `ENV` or Rails credentials, or inheritance from the host's own base
  controller.
- Precompiled, digest-named CSS and JS with embedded fonts, served from a
  manifest whitelist with immutable caching.

### Security

- The dashboard returns 401 by default in every environment, including
  development, until authentication is configured.
- Credentials are compared with `ActiveSupport::SecurityUtils.secure_compare`
  and read per request rather than memoized at boot.
- Assets are served only by exact match against the built manifest, so a request
  can never name a file that was not built.

[Unreleased]: https://github.com/cmer/solid_queue-flightdeck/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/cmer/solid_queue-flightdeck/compare/v0.6.0...v1.0.0
[0.6.0]: https://github.com/cmer/solid_queue-flightdeck/compare/v0.5.3...v0.6.0
[0.5.3]: https://github.com/cmer/solid_queue-flightdeck/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/cmer/solid_queue-flightdeck/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/cmer/solid_queue-flightdeck/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/cmer/solid_queue-flightdeck/releases/tag/v0.5.0
