# Plan 0001: building v1 as a hex package

Date: 2026-10-03. Implements ADR 0001 sections 1-8 (section 11 waits). The
ADR's steps 1-2 are regrouped here into milestones that each leave a working,
publishable package; 1charta's wiring (ADR section 9) lives in 1charta and is
not a step here.

## What being a hex package changes from the ADR

- **No host in this repo.** Every 1charta value (scrub paths, `/b/<id>`,
  `?key=`, `format_status` advice) is host config or docs. CI greps `lib/`
  for `Charta` and `Hologram`.
- **Optional deps really optional.** `Blackbox.Store*` compiles only under
  `Code.ensure_loaded?(Ecto.Adapters.SQL)`, `Blackbox.Plug` under
  `Code.ensure_loaded?(Plug)`. CI runs `mix compile --no-optional-deps
  --warnings-as-errors`.
- **No Jason.** The spike used it; v1 uses OTP 27's `:json`. Postgrex's
  jsonb encoding defaults to Jason, so M2 starts with a test that writes and
  reads `payload` with Jason absent.
- **A switch for hosts' test suites.** `config :blackbox, capture: false`
  (read at boot) skips the install sequence and `backtrace_depth`. Everything
  else is child-spec options: `{Blackbox, repo:, build:, scrub:, spool_dir:}`.
- **Toolchain.** Labs ran on Elixir 1.20.4 / OTP 28; this machine has 1.18.1 /
  OTP 27. Requirement stays `elixir: "~> 1.18"`, OTP 27+ (the ADR's "1.17+"
  is superseded by `mix.exs`). CI matrix: 1.18/27 and 1.20/28. Porting the
  lab suites re-proves their claims on OTP 27.
- **Shipped files** stay `lib mix.exs README.md LICENSE` (plus `CHANGELOG.md` in M5); the
  research (labs, logs, shots) never ships. `mix hex.build --unpack` checked
  in CI.
- **The name** `blackbox` is still free on hex (API 404, 2026-10-03).
  Publishing is outward: only on an explicit "do it".

## Milestones

Each lands tests first (red, then green), green three runs in a row.

**M0 Skeleton** (half a day)
- `mix.exs`: license, links, `docs:` with ex_doc (dev only), `test` alias
  that creates the test DB; drop `hello/0`.
- `test/support/repo.ex` (a Postgres test repo, `DATABASE_URL`),
  `test_helper.exs` with `max_cases: 1`, `backtrace_depth` and the filter
  set explicitly.
- CI: matrix, format, `--no-optional-deps`, the Charta grep, `hex.build`.

**M1 Capture** (ADR 2, 3, 6 minus the store; port of `lab/10-review/lib`)
- `Blackbox.Application` (install + watchdog with pause, resume, give-up),
  `Blackbox.Filter` (`:blackbox_sasl`), `Blackbox.Handler` (level `:all`,
  events vs crumbs), `Blackbox.Telemetry`, `Blackbox.Normalizer` (one clause
  per shape), `Blackbox.Fingerprint` (v1, in-app cache), `Blackbox.Buffer`
  (admission atomics, first/middle/latest samples, writer task, backoff,
  poison policy). Writer is a function, so M1 ships with an in-memory sink.
- Tests: lab 04's failure table, one test per row; lab 08 safety suite with
  SASL tests rewritten for the primary filter; console byte-compare;
  mutations M2, M7, M11 red; 10-1 repeat counts; 10-2 call-site grouping;
  reduction budgets; 1 MB state crash.

**M2 Store** (ADR 6 store attachment, spool, 7)
- `Blackbox` child spec: dynamic one-connection repo, writer, trap exits,
  flush on stop under the shutdown deadline; `Blackbox.Spool` (file on stop,
  import on boot); `Blackbox.Migration` (versioned `up/down`) and
  `mix blackbox.gen.migration`; upsert, derived regression, pruner.
- Tests: jsonb without Jason; DB down 3 s at 10k/s; hung and raising writer;
  boot crash stored once the store attaches; stop puts the buffer in the DB
  or the spool.
- **Dogfood point**: 1charta can take a git dep now (capture + store).

**M3 Before and scrubbing** (ADR 4, 5 scrubbing)
- `Blackbox.Crumbs` (ring, 200-byte binary caps, add-time scrub, per-request
  reset), `$callers`/`client_info` joins, OTP report mining, `Blackbox.Scrub`,
  snapshot + 1 s sampler, `crumb/3`, `set_context/1`.
- Tests: lab 06 joins and ring; `flat_size` bound; the secrets property test
  across every path.

**M4 Page and API** (ADR 8)
- `Blackbox.Plug` (inbox, issue timeline, JSON, `.md`, resolve/mute/note),
  `capture_exception/3`, `capture_message/2`, `capture_browser/2`,
  `current_ref/0`.
- Tests: `authorize` required, `x-blackbox` header, `Host` check, escaping,
  CSP, fence length, browser events out of the default agent listing.

**M5 Release candidate**
- HexDocs: install guide, "what it changes globally" (`backtrace_depth`, the
  filter, debug-level consoles), "still invisible", upgrade/migration notes.
- `CHANGELOG.md` 0.1.0; `mix hex.build`; publish after 1charta has run it in
  prod for a while, on an explicit go.

## Answers (2026-10-03)

1. **MIT** (`LICENSE`, `package.licenses`).
2. **Public repo** at https://github.com/13ue/blackbox.
3. **No hex release for now**: 1charta takes it as a git dependency
   (`{:blackbox, github: "13ue/blackbox"}`); M5 prepares 0.1.0 and publishing
   waits for an explicit go.
