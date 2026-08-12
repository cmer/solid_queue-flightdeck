# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Flightdeck is a mountable Rails engine: a dashboard for Solid Queue (alternative to Mission Control). Runtime dependencies are only `rails` and `solid_queue` — nothing else may be added to the gemspec.

## Commands

```bash
bin/test                                          # asset freshness + fast suite in BOTH host modes
bundle exec rake test                             # fast suite (integration + unit)
FLIGHTDECK_TEST_API_ONLY=1 bundle exec rake test  # same suite, dummy app in api_only mode
bundle exec ruby -Itest test/jobs_query_test.rb   # single file
bundle exec ruby -Itest test/jobs_query_test.rb -n /pagination/   # single test by name
bundle exec rake test:system                      # headless Chrome (skips if no Chrome)
bundle exec rake assets:build                     # rebuild CSS/JS from assets-src/ (commit the result)
bundle exec rake assets:check                     # verify committed digests match
bundle exec rubocop
bin/demo [port] [--no-seed]                       # seeded dummy server, auth off, at /flightdeck
bundle exec rake screenshots                      # regenerate docs/screenshots (headless Chrome)
bin/release [VERSION] [--dry-run] [--skip-ci]     # full release: verify → changelog rollover + version bump → assets → push → wait for CI → tag + gem push + GitHub release (--skip-ci pushes but publishes without waiting for CI)
```

Any change to a view, Stimulus controller, or CSS **requires `rake assets:build` and committing the rebuilt files** — CI's assets job rebuilds and fails on drift. A version bump also changes the built JS (its banner embeds `Flightdeck::VERSION`), so it too needs a rebuild; `bin/release` automates this.

**Never bump the version on a feature branch.** `lib/flightdeck/version.rb` (and the version line in `CHANGELOG.md`) is owned by `bin/release` — it is the only thing that may change it. Feature branches add changelog entries under `[Unreleased]` and leave the version alone.

Maintain `CHANGELOG.md` for user-visible changes — brief and simple: one line per change under `[Unreleased]` in the appropriate Keep a Changelog section (Added/Changed/Fixed/Security), no essays. Internal-only changes (tests, CI, refactors) don't need an entry.

## Architecture

**Rule zero: never monkey patch Solid Queue; never touch the host's connection.** All reads and writes go through `SolidQueue::Record` and the SolidQueue models, so `connects_to` multi-database routing works automatically and semaphore/blocked-execution invariants remain Solid Queue's job. Mutations delegate to Solid Queue's own methods (`FailedExecution#retry`, `Queue#pause`, `Process#prune`, `RecurringTask#enqueue`). No code touches the database at engine load/boot time (host apps must boot with the DB unreachable).

**API-only host support** hinges on engine-local middleware in `lib/flightdeck/engine.rb`: Cookies, CookieStore session (`_flightdeck_session`), and Flash are mounted on the engine only. That is why CSRF, flash, and session work when the host is `config.api_only = true`. The whole test suite runs twice (`FLIGHTDECK_TEST_API_ONLY=1`) to protect this.

**Auth** (`app/controllers/flightdeck/application_controller.rb`): the controller inherits from `Flightdeck.base_controller_class`. Unconfigured → plain-text 401 explaining the four setup options, in every environment. With `config.base_controller_class` set, the host's `before_action`s are the gate and Flightdeck's HTTP Basic is skipped. `AssetsController` is `ActionController::Metal` and deliberately unauthenticated; asset names are whitelisted against the manifest (`lib/flightdeck/assets.rb`) so no user input ever reaches the filesystem.

**Assets have no host-side pipeline.** Committed, digest-named artifacts live in `app/assets/flightdeck/` with `manifest.json`; sources in `assets-src/` (Tailwind v4 CSS, vendored Turbo/Stimulus, Stimulus controllers concatenated by `rake assets:build` — no node, no importmap). `assets-src/input.css` uses `@import "tailwindcss" source(none)` plus explicit `@source` directives: this makes the build byte-deterministic across machines (automatic source detection once scanned CI's `vendor/bundle` and changed the output). Do not remove those directives. New Stimulus controllers go in `assets-src/controllers/` and must be registered in `assets-src/boot.js`. Fonts are vendored woff2 under `assets-src/fonts/` (`fonts.json` is the index; `fetch_fonts.rb` re-downloads them and is the only thing that needs network); `rake assets:build` copies each into the manifest under a digest name and prepends `@font-face` rules with **relative** `url()`s, which is what keeps them resolvable under any mount path. Never inline them as data: URIs again — the point is that a browser downloads only the face it renders in.

**Job state is derived, never stored**: which execution table holds a job defines its state (failed/claimed/blocked/scheduled/ready; `finished_at` on the job row for finished). `Flightdeck::JobsQuery` drives each list from that state's own table, uses keyset pagination (`id < before_id`), caps counts (`count_cap`, rendered "500,000+"), and **never selects `arguments` or `error` in list queries** — previews are fetched per-page with SQL `SUBSTR` and parsed leniently (`ArgumentsPreview`, `ErrorSummary` handle truncated JSON). Tests assert this via SQL capture. Arguments are never deserialized through ActiveJob (job classes may not be loadable).

**`Flightdeck::Metrics::TimeBucket` is the only adapter-specific SQL** — epoch-integer bucketing switched on the adapter (PostgreSQL/MySQL/SQLite), everything UTC; display timezone applies at render only. The CI database matrix (3 adapters × 2 host modes) exists to protect it. Chart series are cached (`Flightdeck::Cache`, swallows store errors → degrades to uncached); charts are server-rendered SVG partials colored by CSS custom properties — no JS chart library.

**Bulk actions** (`Flightdeck::BulkAction`): hard record limit + 10s monotonic deadline + one transaction per batch, "all matching" re-runs the filter server-side (posted IDs are never trusted for it), stopping early is a normal resumable outcome. New destructive actions should subclass `Flightdeck::Jobs::ActionsController` (`target_relation`/`apply`/`past_tense`) to get single/selected/all-matching + toasts for free.

**Hotwire without turbo-rails**: the layout's `turbo-root` meta scopes Turbo Drive to the mount path. Polling panels are turbo-frames with the `refresh` Stimulus controller (visibility- and focus-aware, paused globally by the LIVE toggle via `data-fd-live` on `<html>`). **Every link that leaves a frame needs `target="_top"` on the frame or `data-turbo-frame="_top"` on the link** — `test/integration/frame_navigation_test.rb` crawls all frames and fails otherwise. In `.turbo_stream.erb` templates, render partials with `render partial:, formats: [:html]` (the shorthand misresolves formats).

**Theme tokens** (`assets-src/input.css`): the light and dark palettes are each written once; four selector blocks (OS default, OS-dark guard, `data-theme` stamps) only map tokens to palette entries. `test/theme_tokens_test.rb` enforces the blocks stay in step — add any new token to the palette maps, not to an individual block.

**UI font** (`Flightdeck::UiFonts`): one slug per offered face, stamped as `data-font` on `<html>` from `config.ui_font` and overridden per user by the `font` Stimulus controller. Only the `[data-font]` blocks in `input.css` name a family; every other rule reads `--font-ui`. Adding a face means all four of: vendored woff2, a `[data-font]` block, a `UiFonts::LABELS` entry, and `rake assets:build` — `test/ui_fonts_test.rb` fails if any is missing. The mono face is deliberately not configurable.

## Testing conventions

- The dummy host app is `test/dummy` (schema in `db/schema.rb`, loaded by `test_helper.rb` — there are no working `db:*` rake tasks). It runs API-only when `FLIGHTDECK_TEST_API_ONLY` is set.
- Build queue state with `test/support/solid_queue_scenario.rb` (`create_failed_job`, `create_fleet`, …) — it inserts rows directly, never runs workers. Pass `arguments:`/`error:` as Ruby hashes, not JSON strings (`insert_all!` applies the JSON coder; strings double-encode).
- Anything that changes boot-time config (`base_controller_class`, api_only) must use the subprocess pattern in `test/boot_test.rb` + `test/support/probe.rb`. Never mutate `Flightdeck.config.base_controller_class` in-process — the loaded `ApplicationController` superclass is frozen for the suite and poisons everything after it.
- `Rails.cache.clear` runs in `before_setup`; if a test needs post-action fresh counts, mutations already wrap in `Flightdeck::Cache.bypass`.
- Zeitwerk: one constant per file under `app/models/flightdeck/`.
