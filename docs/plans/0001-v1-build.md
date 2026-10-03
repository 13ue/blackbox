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

## M0 and M1 done (2026-10-03)

67 tests (5 flood), green three runs in a row on Elixir 1.18.1 / OTP 27;
9 of 9 mutations turn a test red (M2, M7, M11, filter off, no dedupe,
dedupe ignoring the source, no reported-pid check, no size bound, no
binary copy). What the build found and decided:

- **On Elixir 1.18 the translator turns OTP reports into text** before any
  handler: `last_message`, `state` and `client_info` are gone by then (lab 08
  ran on 1.20). So the primary filter takes every labeled report at `:error`
  (and `{:application_controller, :exit}` at any level) raw, and marks its
  `meta.time` in the process dictionary; the handler skips that same event.
- **Dedupe key is `{kind, reason}`, not `{fingerprint, reason}`**: Phoenix,
  Bandit and the log carry the same exception term but not always the same
  stack, so the key does not depend on frames. Sources are the telemetry
  event name, `:logger`, or `{:filter, label}`.
- **A supervisor's `child_terminated` is skipped when the child reported**:
  every in-process crash puts its pid in a public ETS set (pruned after 5 s),
  which the supervisor's report takes. Kills and link deaths, which no child
  reports, stay as `exit :killed` with the child id as label.
- **Crash cost** in the failing process: 823 reductions, ~10 µs with 12
  frames and 20 crumbs (the spike's 33-40 µs formatted there). A crash with
  a 1 MB state costs +175 µs and sends `{:too_big, words}`.
- **Fingerprints now hash arities**, not a frame's arguments (a BIF frame
  carries them, so `Map.fetch!(m, :a)` and `(m, :b)` split).
- Deferred, marked in code: merging fields across sightings (the first
  sighting wins), restart counts on the child's issue, crumb binaries nested
  two levels down.

## M2 done (2026-10-03)

87 tests (7 flood), green three runs in a row; CI green on 1.18/27 and
1.20/28; 7 of 7 store mutations turn a test red (count replaced instead of
added, no flush on stop, no spool import, no spool write, no retention,
builds not tracked, writing on the host's pool).

- `{Blackbox, repo: MyApp.Repo, build: ..., spool_dir: ...}` starts a
  one-connection pool of the host's Repo (`start_link(name: nil, pool_size:
  1)` and `put_dynamic_repo/1` in the writer). A test holds every host
  connection and the write still lands.
- **No JSON library**: Postgrex encodes `jsonb` with Jason by default; the
  store sends the payload as text from Elixir's `JSON` and casts `::jsonb` in
  SQL, so the host's Postgrex config does not matter.
- Writes are raw SQL over `unnest` arrays in one transaction: upsert issues
  (count added, `builds` appended), insert occurrences, keep the last 100 per
  touched issue; the 30-day prune runs every 10 minutes on the same pool.
- Stop: the store drains the buffer within 4 s (shutdown 5 s). The buffer
  traps exits and spools what is left to `spool_dir`; the next attach
  imports and deletes the file. Known ceiling, marked: a batch committed in
  the instant before the kill is spooled too and counted twice.
- `Blackbox.Migration.up/down(version: 1)` and `mix blackbox.gen.migration`.
- Floods into Postgres: 50 000 at 10k/s stored exactly; the database down
  for 3 s at 10k/s, 30 000 of 30 000 stored once it is back.
- Seen, not fixed: when the database is down, DBConnection's own
  "tcp connect refused" errors (from the host's pool and ours) are captured
  as issues. They are true, but ours duplicate the host's.

**Dogfood point reached**: 1charta can add `{:blackbox, github: "13ue/blackbox"}`,
the migration, and the child after its Repo.

## M3 done (2026-10-03)

104 tests (7 flood), green three runs in a row; 11 of 12 mutations turn a
test red, and the twelfth showed dead code (the writer's re-entry flag, now
removed: its Logger metadata already keeps it out).

- **`Blackbox.Scrub`**, once, in the buffer before formatting; crumb text
  and data when added, so no process dictionary holds a secret. Keys: the
  defaults, Phoenix's `filter_parameters`, `config :blackbox, scrub_keys:`;
  a key matches when its name contains one. Text: `key=value`, `key: value`,
  `"key" => value`, and `scrub_patterns` (regex strings, group 1 replaced).
  Exceptions with values become shapes; `Postgrex.Error` loses `detail`,
  `hint`, `where`; `FunctionClauseError` its args.
- **The secrets test found two leaks the ADR did not list**, both fixed in
  the lib rather than left to the host: the `:sys` log holds raw call and
  cast messages even when `format_status/1` redacts `message` (now reduced to
  tags), and a callee's `function_clause` nests a stack frame with the call's
  arguments inside the caller's exit reason (nested frames now keep arity
  only). 15 secrets, 3 rounds, none in the tables, the spool or a dictionary.
- **Cost of add-time scrubbing**: a log crumb is 63 reductions raw, 2.2 µs
  with the regex; a `:binary.match` pre-check on the key names brings it to
  0.4 µs (84), and one host pattern to ~0.7 µs (123). Kept as text crumbs;
  budget 150. Known ceiling, marked: mixed-case key names in text skip the
  key regex (lower, Capitalized and UPPER are checked).
- **Crumbs from telemetry**: Bandit request start and Phoenix endpoint start
  reset the ring (06-42); the request line (path scrubbed, no query), the
  route, Finch calls (method, host, status, ms), Ecto queries (source,
  ok/error, ms; never SQL or params), attached by the store with the repo's
  telemetry prefix.
- **`Blackbox.set_context/1`**, merged over the caller's through `$callers`.
  **System snapshot** per failure: run queue, process count and limit, the
  process's mailbox, memory and reductions, node memory from a 1 s sampler.
- Patterns are the host's; a pattern that also matches route templates
  (`/b/:id`) filters them too, so the documented example skips `:` segments.
- Deferred: the `$ancestors` join (a GenServer's ancestor is its supervisor,
  which keeps no crumbs), debug crumbs per module with the console level
  kept, OTel trace ids.

## M4 done (2026-10-03)

122 tests (7 flood), green three runs in a row; 9 of 10 page and API
mutations turn a test red (the tenth, letting `key` through
`capture_browser`, is caught by `from_browser` building the report from four
fields: two layers, kept).

- **`Blackbox.Plug`**: the inbox (regressed, new, open first; the node's
  counters and what Blackbox cannot see at the foot), the issue page (state,
  actions, the recommended occurrence: most crumbs and locals of the latest
  20; one timeline in seconds relative to the failure; in-app stack open,
  dependency frames folded; locals, context, process, system), `/refs/:ref`.
- **The API**, `/api/v1`: issues with `state`, `source`, `since_build`,
  `limit`; one issue as JSON or Markdown; refs; resolve, mute (until a date
  or N more), reopen, note.
- **Security**: `authorize` required (`localhost?/1` checks the peer and the
  `Host` header; `token/1` takes Bearer or Basic, constant-time); POST needs
  `x-blackbox`; other methods 405; a CSP with a per-response nonce, nosniff,
  no-referrer, no-store; every event string escaped; Markdown fences longer
  than any backtick run, after "data, not instructions"; browser events out
  of the default listing and marked untrusted.
- **State derived on read**: regressed = resolved, seen since, and `builds`
  no longer within the builds seen at resolve (an old build during a deploy
  stays resolved); muted until a date or a count.
- **Refs**: `<fingerprint prefix>-<5 random>`, set in the failing process
  (the error page reads `current_ref/0`), stored per occurrence; a ref whose
  sample was only counted still finds its issue by the prefix.
- `capture_exception/3` (a later reraise is the same failure),
  `capture_message/2` (grouped by the caller's site, found below Blackbox's
  frames because the public call is a tail call), `capture_browser/2` (four
  fields, capped, grouped by name and masked top stack lines).
- **A fresh host app** (path dep, `mix blackbox.gen.migration`, the child
  after its Repo) ran end to end and found two scrub flaws, fixed: KeyError's
  `key` field was filtered for its name (`key`), and text scrubbing was not
  idempotent around quoted `"[Filtered]"`; also `key :missing` was read as
  `key: value` (a colon now has to follow the key directly).

## M5 done (2026-10-03)

README as the install guide (setup, config, the explicit API, agents, what
it changes globally, what it cannot see, measured costs), CHANGELOG 0.1.0
(unreleased), HexDocs with both as extras; `mix docs` without warnings;
`mix hex.build` ships lib, mix.exs, README, LICENSE, CHANGELOG. The ring's
real size, measured: ~7 KB for 50 short lines, ~36 KB at most (the ADR's
15 KB counted the heap only). **Not published**: 1charta takes the git
dependency first; hex waits for an explicit go.
