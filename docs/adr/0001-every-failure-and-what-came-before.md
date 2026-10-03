# ADR 0001: Every failure on the BEAM, and what came before it

Status: Accepted

This is 1charta's ADR 0031, carried over as this repo's first record on
2026-10-03. Section 9 is 1charta's wiring; the rest is Blackbox.

Date: 2026-09-27, revised after review the same day, accepted 2026-10-03

## Context

The ask, verbatim: "as a new lib (kept inside this repo for now, planned to be
a separate hex package) we want to build the most useful and amazing
error/exception/bug tracking observibility tool for elixir there ever could
be. it should get ALL errors that occur in the beam. sync and async,
listening to phoenix but also everything else. have a look at the sentry for
elixir package, how do they do? we also want to track more additional
information, especially what happenened before any given error. make an
enoourmous reserach effort here and prove TDD everything technical that is
not clear. write an ADR/research artifact."

Eight agents ran in parallel: a source read and lab of sentry-elixir (01),
every other BEAM tool read from source (02), the field beyond Elixir with
counted developer quotes (03), a lab of every way a BEAM process can fail
(04), a lab of Phoenix, Bandit, Cowboy, channels, LiveView, Ecto, Oban, Req
and Hologram (05), a lab of what can be known before a failure, with costs
(06), 1charta's own error surface and the packaging (07), and a spike of the
whole core, end to end (08). The readable result is the artifact **1charta
Blackbox**: https://claude.ai/artifact/PVdxZZrQZX5G4BCjX2wqHS, kept in this repo as
`docs/research/0001-errors/index.html` beside the reports, logs and labs. After the draft, a ninth agent did a
heavy-scrutiny review (report 10): it reran every suite, added 17 tests and 12
mutation checks, found three blockers and fourteen serious issues, and this
ADR was revised on all of them (see "What the review changed").

**How "prove TDD" was done.** Every technical claim that was not obvious
became an ExUnit test written before it was run, with the assertion the
agent believed. The first outcome was recorded; a red test meant the belief
was wrong, and its assertion was then changed to what the BEAM really does.
Five labs, **256 tests, 54 of them red on the first run**, every suite
green three runs in a row on Elixir 1.20.4 / OTP 28, Apple M3 Pro:

| lab | tests | red first | what it proved |
|---|---|---|---|
| `lab/01-sentry` | 27 | 7 | what sentry 13.5.1 really catches |
| `lab/04-beam` | 72 | 20 | what every failure path sends to a `:logger` handler |
| `lab/05-frameworks` | 65 | 13 | what each framework reports, and how often |
| `lab/06-before` | 52 | 7 | what can be known before a failure, and its price |
| `lab/08-spike` | 40 | 7 (+26 against no code) | the whole core under floods and faults |
| `lab/10-review` | 17 + 12 mutations | 2 | the review's doubts, and whether the spike's tests catch broken code |

One caveat from the review: on its rerun, 05-43 failed once under full-suite
load (the pool closed the socket before `query_canceled`) and passed 5 of 5
alone.

Many of this ADR's decisions exist because a test went red. They are marked
with the test id.

### What sentry-elixir does (report 01)

- **Its logger handler is off by default** (`enable_logs: false` in 13.5.1),
  so out of the box a GenServer, Task or process crash is not reported at all
  (01-1). Issue #1047 "enable by default" is open.
- **Phoenix on Bandit, set up as the docs say, loses controller 500s** (01-3):
  PlugCapture is documented for Cowboy only, and the handler's default
  excluded domains flipped five times since 2024.
- **Duplicates are fought by ignoring log domains**, and `Sentry.Dedupe` hashes
  the whole event, so the PlugCapture + handler pair is sent twice (01-5).
  Dedupe is a silent 30 s sliding window with no counter (01-6, 01-7).
- **Crash events carry neither the last message nor the state** when a
  callback raises, the common case (01-2a, red).
- **Breadcrumbs are manual**, with whole-second timestamps, in Logger
  metadata (01-8).
- **Grouping is the server's job**; the one fingerprint the client sets
  (call timeouts) includes the call's arguments and floods (#933).
- **The app pays**: the event is built in the crashing process (52-62 µs);
  when Sentry is slow, 17 of 300 calls blocked 50 ms or more (01-9); when it
  is down, retries of 1+2+4+8 s and unbounded mailboxes (#932).

Worth copying: the logger handler as the base, a domain that stops the
reporter from reporting itself, the `$callers` context lookup, the Oban and
telemetry-handler-failure integrations, the scrubber defaults.

### What the rest of the BEAM field does (report 02)

- **No tool catches everything.** ErrorTracker, the only self-hosted one, has
  no `:logger` handler at all: GenServer, Task, spawn and Hologram crashes
  never reach it. Tower, AppSignal and Honeybadger work only because Elixir's
  translator adds `crash_reason`; Honeybadger regex-parses formatted text.
  Only New Relic reads the structured OTP report.
- **OTP reports carry data nobody uses**: `last_message`, `state` (already
  through `format_status/1`), the `:sys` log, `client_info` (the caller's pid
  and stack), `process_label`, the process dictionary, links
  (`gen_server.erl:2764-2815`, `proc_lib.erl:963-1090`).
- **Safety gaps everywhere**: OTP removes a raising handler and telemetry
  detaches a raising one, and no tool re-attaches; ErrorTracker writes to the
  DB inside the crashing process; Honeybadger and Rollbax use one unbounded
  mailbox; Bugsnag starts a Task per error.
- **Fingerprints break easily**: file:line or the full stack with lines.
- Worth copying: ErrorTracker's issue/occurrence upsert, reopen on recurrence,
  mute, pruner and versioned migrations; Tower's reporter behaviour and loop
  guard; New Relic's process-dictionary marker for dedupe; observer_cli 2.0's
  versioned JSON for agents.

### What the wider field and its users say (report 03)

- **Noise is why people switch trackers off** (8 of 47 on-topic HN comments).
  The fix is issue state: new, regressed after a fix tied to a release,
  escalating against its own baseline, muted until a date or count. Notify on
  the first three only.
- **Every tool keeps "before" as a bounded ring shipped only with an error**:
  Rollbar 100 events, Honeybadger 40, Sentry replay 60 s, Go's FlightRecorder
  by bytes, JFR under 1 % overhead.
- **Local variables are the most loved context** (HN 41754386: 17 of 44
  comments). The BEAM's equivalent is the top frame's arguments plus the
  GenServer's last message and state.
- **Self-hosted Sentry is too heavy** (16 GB+, Kafka, ClickHouse; 29 of 150
  comments in HN 43725815); people move to GlitchTip and Bugsink. Run inside
  the app, in its Postgres, with no extra services.
- **Agents**: about 6 of sentry-mcp's ~61 tools matter. CERT VU#212479
  ("PhantomFix", 2026-09-16): a forged error sent to a public ingest key
  steered Seer's coding agent into running attacker code. Event text is
  untrusted data, there is no public ingest, the tracker never runs fixes.

### What the BEAM really sends (reports 04, 05, 06, 08)

- **Elixir hides the supervision layer by default.** Its primary
  `logger_translator` filter runs with `sasl: false` and stops every
  `[:otp, :sasl]` report before any handler: GenServer `init` crashes,
  supervisor restarts, max-intensity give-ups and brutal kills produce zero
  handler events (04-15, 04-27..29; 06-9 and 08-7 red first). Setting
  `Logger.configure(handle_sasl_reports: true)` at runtime does nothing
  (08-7, red). A primary filter of our own, added with
  `:logger.add_primary_filter/2`, runs *before* Elixir's translator and sees
  those reports without changing any setting or the console (04-71, 04-77).
- **Some deaths leave no trace anywhere**: `exit(:boom)`, kills and death by
  link of an unsupervised process, `{:shutdown, _}`, call and await timeouts
  on the caller side (04-3, 04-8, 04-11, 04-12, 04-20, 04-23). A supervised
  child's kill is visible only as the supervisor's `child_terminated` report.
- **Rescued exceptions, `{:error, _}` and `catch :exit` reach no handler**
  (04-40). An OTP 27+ trace session on `erlang:error/1,2,3` and `throw/1` sees
  most of them for ~0 on the happy path and +0.35 µs per raise, but misses
  VM-instruction errors (badmatch, case_clause) (04-45, 04-51). `exception_trace`
  slows every process ~4.5x: never always-on (04-51).
- **Neither hook alone is enough.** The logger misses every Oban failure (Oban
  logs nothing by default) and every exception with `plug_status` < 500;
  telemetry misses channels, LiveView `handle_info`, Tasks, DBConnection and
  Bandit protocol errors (05-7, 05-26, 05-35, 05-45).
- **One HTTP 500 is seen 3 to 4 times** (Phoenix router_dispatch exception,
  error_rendered, Bandit exception, the log). On Bandit all run in one
  process, telemetry first, logger last, so a process-dictionary mark dedupes
  them for 0.1 µs (05-5, 05-6, 05-59). Cowboy splits the failure across two
  processes; the fallback is a content key in ETS, 1.9 µs (05-19, 05-60).
- **The handler runs in the process that logged**: the dying process for
  every proc_lib process (GenServer, Task, Agent, gen_statem, Bandit
  connection), the caller for `Logger.error`, `:logger_proxy` for a plain
  `spawn` crash (04-63, 06-3, 06-8). A 20 ms handler adds 20 ms to every
  `Logger.error` (04-63). So the dying process's own dictionary is readable at
  crash time, for free.
- **A handler that raises is removed silently**, announced only at `:debug`;
  a handler that logs re-enters itself with no guard (04-60, 04-64, red).
- **Under a burst the VM itself drops crash reports**: 10k crashing `spawn`s at
  once deliver 1,665-4,799; `:logger_proxy`'s drop mode leaves one uncounted
  `:notice` (04-68, red). Paced at 10k/s they all arrive (08). The logger core
  drops nothing (04-65). The console handler writes 500 of 10,000 (04-66).
- **Stacks are short or missing**: `backtrace_depth` is 8 in production (ExUnit
  silently sets 20, so tests lie), a throw in a callback becomes
  `{:bad_return_value, v}` with `[]` (04-19, 04-34). `meta.mfa` of an OTP crash
  is `{:gen_server, :error_info, 7}`, not the app's code (08-2, red).
- **Application exits arrive at `:notice`**, below `:error` (04-37, red).
- **Linking a crash to its request works, cheapest first** (06-49..53):
  the dying process's own ring; a Task's `$callers` to the parent's dictionary
  (11 µs); a GenServer crash inside a `call` names the caller in `client_info`
  (06-12, red: `last_message` is the bare request); a cast or send is joined
  only by a `seq_trace` label, which travels through call, cast, send and spawn
  for 128 ns per call and is inherited by spawned processes (06-22..27; 06-25
  red). Work that outlives its request finds a dead parent.
- **Bandit runs all keep-alive requests of a connection in one process**
  (06-42): reset the ring on `[:bandit, :request, :start]` or request N's
  crumbs appear in request N+1's crash.
- **Costs** (06, 08): a crumb 42-160 ns into a process-dictionary ring
  (4.4 KB for 50); a telemetry crumb 125 ns; full capture +5 µs p50, +45 µs
  p99 per request in-process, invisible over HTTP; almost all of it from
  lowering the primary Logger level to `:debug` (06-46). `put_process_level`
  cannot open debug for one process (06-47, red); per-module levels can. One
  GenServer as a crumb store drowned (8.5M queued in 3 s); an ETS ring leaked
  59 MB of dead pids' rows.
- **`:sys.log` is a built-in flight recorder**: +56 ns per call, switchable at
  runtime, lands in the terminate report's `log`, and leaks the secrets
  `format_status` removed from `state` (06-28..35).
- **OTP 28 `trace:system/3` gives each trace session its own system monitor**,
  ending the one-per-node limit (06-32, 06-39): long_gc, large_heap,
  long_message_queue without fighting anyone for it.
- **The spike held** (08): 432 lines; 10k to 200k `Logger.error`/s, 10k Task
  and 10k spawn crashes/s, sent == counted in Postgres, 0 dropped, app p99 30
  to 98 µs; a raising writer, a hung writer (killed at 500 ms), the DB down
  3 s at 10k/s (30 000 of 30 000 stored after), a poison event, its own logs:
  all survived. It found a real bug (monotonic time is negative, 08-31) and a
  1.4 ms cost trap (`:application.get_application/1` 11 µs, formatting 20 µs
  per frame), now 33-40 µs per crash in the failing process (measured with 12
  frames and 20 crumbs). But every flood used one fingerprint, its dedupe
  drops real repeats uncounted, and its SASL tests used the translator route,
  not the primary filter decided below (review 10).

### What the review changed (report 10)

- **Blocker: the handler level contradicted the crumbs.** A `:notice`
  handler never receives `:info` (10-12), so the draft's info crumbs through
  the handler could not work. Now the handler runs at the host's level and
  splits events from crumbs in `log/2` (section 2.3).
- **Blocker: 1charta's privacy was not met.** Last messages carry board ops
  and chat text positionally (`{:apply, ops, ...}`, `{:say, from, text}`),
  exception messages embed values (Postgrex `Key (name)=(my-private-space)`,
  `KeyError` prints the map; 10-11), crumbs held raw `/b/<id>` lines, and
  `/tab/error` posts the board key. Section 5's scrubbing and 9.4 now cover
  `state`, `message` and `log`, value-bearing exception fields, call messages
  inside exit reasons, and crumb text at add time.
- **Blocker: boot and shutdown lost the failures that matter most.** Started
  after the Repo, nothing caught boot crashes; nothing flushed on stop, so a
  deploy's last batch and a `start_permanent` halt's cascade died with the VM.
  Capture now starts from Blackbox's own OTP application and flushes on stop
  (section 6).
- **Dedupe dropped real repeats uncounted** (10-1); a mark hit now counts.
  **Log grouping split per line on letter ids** (10-2: ~20 000 issues from
  20 000 lines); logs now group by call site. **Three spike tests passed on
  broken code** (fun-index strip, frame selection, ring bound; mutations M2,
  M11, M7); step 1 adds tests that fail on those mutations.
- **Deferred as unproven or unneeded for 1charta**: the `seq_trace` label (it
  leaks into the lib's own writer and the DB pool, 10-9a, and was never joined
  to a trail), the finished-trail table, the OTP 28 system-monitor session,
  crash-dump import, `escalating`, Cowboy, LiveView and Oban attachments, dev
  issue files, the store behaviour. Steps 1-2 now port the spike instead of
  rebuilding it.
- **What held up**: the primary filter runs first, survives
  `Logger.add_translator/1` (10-7), costs noise (10-8), and a raising filter
  is removed without stopping logging (10-5); 9 of 12 mutations turn the
  spike's tests red; the DB-down test reran 30 000 of 30 000; report 01 reran
  27 of 27.

### What 1charta has today (report 07)

- **No error history.** Logs go to stdout only; the container is recreated on
  every deploy with a 50 MB cap. 168 h of prod logs: 3,683 lines, all
  `[info]`.
- **Privacy is the hard constraint.** Board keys are in request paths
  (`/b/<id>`, `?key=ck_`); a `Charta.Board.Server` crash would put the whole
  board into the report as state, because there is no `format_status/1`.
- **A browser error tracker already exists and nothing reads it**:
  `board.js` (`reportError`, the `fetch("/tab/error"` near line 5904) posts to `/tab/error`, rows land as `tab_error` board
  events (60 per board per minute, pruned after 30 days); sealed boards send
  only same-origin frames.
- **No error id a person or an agent can quote** on the error page or JSON.
- **Hologram needs no hook in the lib**: commands raise inside
  `ChartaWeb.Endpoint` with no rescue (`deps/hologram/lib/hologram/controller.ex:355`),
  so Bandit and the logger see them; actions run in the browser. Gaps: an
  unencodable command result is a 200 with `status: 0` and no log; SSE
  processes die by `max_heap_size` kill, a VM report with no exception. All
  commands group under `/hologram/command`; the module and name are only in
  the body.
- **Swallowed errors**: three rescues log a warning without a stacktrace
  (`board/server.ex:441, 482`, `notes.ex:935`); `spaces.ex:847, 1096` turn any
  `Postgrex.Error` into "name taken", so a DB outage reads as a taken name.
- The `erl_crash.dump` in the repo root (2026-09-20) came from a `mix test`
  run whose IO server was gone, not from 1charta.
- **Packaging**: a path dep at `packages/blackbox` works with `mix release`
  if the Dockerfile copies `packages` before `mix deps.get`, the dev reloader
  gets `reloadable_apps: [:charta, :blackbox]`, and the lib is never called
  from Hologram actions (Hologram puts every loaded module in its call graph).
  The package's own `mix test` has its own `_build` and is safe beside the
  dev server. `blackbox` is free on hex (2026-09-27).


## Decision

Build **Blackbox**, a flight recorder for the BEAM: it catches every failure
it can see, keeps what happened before each one, stores it in the app's own
Postgres, and shows one timeline per failure to people and agents. A general
hex package, used by 1charta first. v1 is the spike, ported and hardened, not
a rewrite; everything the review found unproven or unneeded for 1charta
waits (section 11).

### 1. Where it lives

- Its own repository (`~/Projects/blackbox`, `mix new blackbox --sup`,
  2026-10-03); 1charta depends on it as a git dependency until the hex
  release. Module `Blackbox`.
- **Its own OTP application.** Capture starts when `:blackbox` boots, which is
  before `:charta`, and stops after it, so boot and shutdown failures of the
  host are seen (review R-3).
- Requires OTP 27+ and Elixir 1.17+ (`:json`, `process_info(pid,
  {:dictionary, key})`); no fallbacks for older OTP (R-26).
- Hard dependency: `:telemetry`. Optional: `ecto_sql`/`postgrex` (the store),
  `plug` (the page and API). Framework telemetry is attached by event name,
  so Phoenix and Bandit are never deps.
- Nothing in the package names `Charta` or `Hologram` (a CI grep). 1charta's
  glue lives in 1charta.
- Hex later: swap the git dependency for a version.

### 2. What it catches: one install

When `:blackbox` starts it runs one install sequence; a watchdog repeats the
checks every 5 s.

1. **`:erlang.system_flag(:backtrace_depth, 32)`** (configurable; 04-34; the
   cost of 32 over 8 is noise, 10-16).
2. **A primary filter of our own, first in line**, `:blackbox_sasl`. It runs
   before Elixir's translator (04-71; `Logger.add_translator/1` keeps it
   first, 10-7), and takes what the translator would stop: `[:otp, :sasl]`
   reports (init crashes, proc_lib crash reports, supervisor child_terminated,
   start_error, shutdown; 04-72, 04-75), `[:supervisor_report | _]`, and
   `:error` reports with a label the normalizer does not know (08-17b). It
   returns every event untouched, so handlers and the console behave as
   before (04-77). It is a domain match and a return for everything else
   (cost noise, 10-8). Its body is wrapped like the handler's: OTP removes a
   raising filter and tells only stdout (10-5), and a restart of Elixir's
   Logger app removes it too (10-6); the watchdog re-adds it. No setting
   changes. (The alternative, `handle_sasl_reports: true` plus a stop filter
   on the console, works, 04-76, but changes a setting the user sees.)
3. **One `:logger` handler, level `:all`**, id `:blackbox`: the primary level
   already decides what arrives. `log/2` makes **events** of `:error` and
   above, `{:application_controller, :exit}` at `:notice`,
   `removed_failing_handler` and `logger_proxy` drop-mode notices; everything
   else becomes a **crumb** (section 4). (A `:notice` handler never sees
   `:info`, 10-12.)
4. **Telemetry**, attached only for loaded apps: `[:phoenix, :router_dispatch,
   :exception]`, `[:phoenix, :error_rendered]`, `[:plug, :router_dispatch,
   :exception]`, `[:bandit, :request, :exception]`, `[:telemetry, :handler,
   :failure]`, plus the crumb events of section 4.

**The watchdog** re-adds a removed handler or filter, re-attaches detached
telemetry, and records "capture was off for N s" as the lib's own event.
`Blackbox.pause/0` and `resume/0` stop it from fighting an operator; after 5
re-adds in 10 minutes it gives up with one event, so a body that raises
before its `catch` cannot loop (R-21).

**The explicit API** for what no hook sees:
`Blackbox.capture_exception(e, __STACKTRACE__, opts)` for rescues,
`Blackbox.capture_message/2`, `Blackbox.crumb/3`, `Blackbox.set_context/1`,
`Blackbox.capture_browser/2`, `Blackbox.current_ref/0`.

**Set now, used later:** 1charta sets `ERL_CRASH_DUMP` on its data volume, so
a dump exists when the import is built (section 11).

### 3. One failure, one occurrence

- **Normalizer**, one clause per shape, with the lab's cases as fixtures:
  emulator `{:string, _}` + `crash_reason`; `{:gen_server, :terminate}`;
  `{:gen_statem, :terminate}` (3-tuple reason, `queue`); `{Task.Supervisor,
  :terminating}`; `{:proc_lib, :crash}`; `{:supervisor, :child_terminated |
  :start_error | :shutdown}`; `{:application_controller, :exit}`;
  `{GenServer, :no_handle_info}`; `Plug.Conn.WrapperError` (the inner conn is
  the right one); the OTP `max_heap_size` kill report. The kind is recovered
  (`{:nocatch, v}` is a throw). Unknown shapes are kept as "unrecognized",
  never dropped.
- **Dedupe by source, in the process**: each failure leaves a mark in the
  process dictionary, `{key, sources}` with `key = {fingerprint, reason
  hash}`, for 1 s. A sighting from a source the mark has not seen yet (the
  logger after telemetry, the proc_lib report after the gen_server report,
  `error_rendered` after `router_dispatch`) is the same failure: it merges its
  fields (Bandit's conn) and counts nothing. A sighting from a source the
  mark already has is a **new failure** and counts (10-1: the spike's single
  mark dropped real repeats uncounted, R-5). Up to 8 marks per process.
- **Supervisor reports**: a `child_terminated` is merged into the child's
  event when the child reported; kept as `exit :killed` when it is the only
  witness (08-34, 08-35); a give-up is its own issue (08-36). Restarts count
  on the child's issue.
- **Expected is not an error**: `Plug.Exception.status/1` < 500, `:normal`,
  `:shutdown`, `{:shutdown, _}` are counters per kind, shown on the list
  page, not issues.

### 4. What came before

**The crumb ring.** Every process that logs or emits a crumb event keeps a
ring in its own process dictionary: 50 entries, `{count, list}`, trimmed at
100, µs timestamps (42 ns per add, 06-6, 06-7). No shared store (one
GenServer drowned, an ETS ring leaked; 06). Crumbs hold small terms only:
binaries are copied and capped at 200 bytes when added, because a 100-byte
slice kept a 4 MB binary alive (10-10, R-16). Ceiling: about 15 KB per
process that ever logged, cleared per request; a test asserts the ring's
`:erts_debug.flat_size` bound (the spike's ring passed every test untrimmed,
M7).

**Default crumb sources**, all in the process that does the work:

- Logger events below `:error` at the host's level, through the handler.
  Their text is scrubbed **when added** (section 5), so the dictionary, which
  shows up in `Process.info/2`, observer and crash reports, never holds a
  secret. The add-time cost is measured in step 2; if it breaks the budget,
  crumbs keep the call site and metadata only.
- Telemetry of loaded libs: Phoenix endpoint and router, Bandit request, Ecto
  queries (source, duration, result, never params), Finch/Req requests
  (method, host, status, duration), each with a short allow-list of fields
  (125 ns each, 06-18).
- `Blackbox.crumb/3`.
- Debug crumbs are opt-in per module (`Logger.put_module_level/2`). Turning
  them on also sets the console handler's level to the old primary level, so
  the console does not start printing them; the docs say this is a setting
  change (06-2, R-23).

**The ring resets per request** on `[:bandit, :request, :start]` and
`[:phoenix, :endpoint, :start]`, because Bandit runs every keep-alive request
of a connection in one process (06-42, 06-43).

**Joining a failure to its cause**, inside the handler, before anything
leaves the dying process (06-49..51): (a) the dying process's own ring and
Logger metadata; (b) `$callers` then `$ancestors` to a live parent, read with
`Process.info(pid, {:dictionary, ...})` (11 µs, only on failure); (c) a
GenServer crash in a `call`: the `client_info` pid's ring (06-12, 06-51).
Casts, sends and work that outlives its request are **not joined in v1**
(the label is deferred, section 11).

**What OTP already carries**, mined from the report as terms: `last_message`,
`state`, the `:sys` log, `client_info` with the caller's stack, `$callers`,
`$ancestors`, `process_label`, `message_queue_len`, links. Shown as "locals",
after scrubbing (section 5).

**System at that moment**, fixed sub-µs fields per failure: run queue,
process count against the limit, the process's mailbox length, memory,
reductions (06-15). `:erlang.memory/0` (47 µs) comes from a 1 s sampler.
Plus node, build and OTel trace/span ids when an SDK is present.

### 5. The event, the grouping, the scrubbing

- **Occurrence** (one wide row, a JSON `payload` for the rest): issue, kind
  (`:error | :exit | :throw | :log | :browser`), source, type (exception
  module or exit-reason shape), message, stacktrace with an in-app flag per
  frame (paths repo-relative), fingerprint, grouping version, build, node,
  pid, label, registered name, the causal chain, a 0.2 KB request/job summary
  (never the conn; 05-16), locals, trail, system, `at` (the sample's own
  time, not the write time; R-20).
- **Fingerprint v1**: `sha256(kind, type, top 3 frames)`, where the frames
  are the top 3 **in-app** frames (modules of the host's own apps, looked up
  once and cached; 08: `:application.get_application/1` costs 11 µs), as
  `{module, function with the anonymous-fun index stripped, arity}`. No
  lines, messages or arguments. Fallbacks, in order: no in-app frame within
  the depth, the top 3 frames of any app; an empty stack, the process label,
  registered name or initial call (not one issue for every `:killed` on the
  node). **Logs group by call site**, `{mfa, line}` from Logger metadata, and
  only fall back to the masked template (numbers, pids, refs, UUIDs, any
  token with a digit) when there is no call site (10-2, R-7). Exits group by
  shape (`{:timeout, _}`). Known ceiling: a remote tail call into a function
  that raises erases the caller's frame, so the next frame up decides (10-3).
- **Issue state**: `open`, `resolved` (with the build it was resolved in),
  `muted` (until a date or a count). **Regressed** is derived when read: an
  occurrence after the resolve, from a build the issue had not seen before the
  resolve. An occurrence from an old build still running during a deploy
  stays on the resolved issue (review section 6: a simpler state machine).
- **Scrubbing, once, centrally, in the buffer** (crumb text at add time):
  - keys: the host's `:phoenix, :filter_parameters` plus `password, token,
    secret, authorization, cookie, api_key, key`, in maps, keyword lists and
    structs, everywhere;
  - paths and query keys by host patterns (1charta: `/b/<id>`, Space links,
    `?key=`), in request summaries, crumb text and messages;
  - **call messages inside exit reasons** (`{_, {GenServer, :call, [_, msg,
    _]}}`) are reduced to their tag (`{:apply, ...}`), because a key scrubber
    never sees positional content (R-2);
  - **exceptions whose fields carry values** are scrubbed field by field and
    their message recomputed from the scrubbed struct: `KeyError.term`,
    `MatchError`, `CaseClauseError`, `WithClauseError`, `BadMapError`
    terms (kept as a shape: type and keys), `Postgrex.Error` (its `detail`
    and query params dropped: `Key (name)=(my-private-space)` is personal
    data, 10-11), `FunctionClauseError` args (arity only). Other messages are
    capped at 1 KB and path-scrubbed;
  - `state`, `last_message` and the `:sys` log go through the host's
    `format_status/1` first (it receives all three), then the key scrubber,
    then a byte cap (06-35: the log leaks what a state-only `format_status`
    removed);
  - `[Filtered]` shows a value existed.
  A property test in step 2 feeds known secrets through every path (params,
  state, last message, `:sys` log, exit reasons, exception messages, crumbs,
  browser posts) and asserts none reaches the database.

### 6. Never hurt the app

The spike's pipeline, as proven (08-14..18, 08-27..32), with the review's
fixes:

- **In the failing process**: classify, fingerprint on raw frames, read the
  ring, set the dedupe mark, `send` the **raw, bounded** terms to the buffer.
  Bounded means: if `:erts_debug.flat_size` of `state` or `last_message` is
  above 64k words, a `{:too_big, words}` marker is sent instead. No I/O, no
  calls, no `inspect`, no regexes there (the spike did format there; its
  12.6-14.9 µs per `Logger.error` and 33-40 µs per crash include that, R-13).
  Step 1 measures the move, and a crash with a 1 MB state.
- **Budgets in reductions, not wall time**: each capture path asserts a
  reduction count in a test; wall time is measured and logged, never
  asserted (08-33's wall-clock bound went red twice on a shared machine,
  R-14).
- **Admission**: an `:atomics` in-flight counter; past 10 000 it drops and
  counts, exactly (08-18).
- **One aggregating buffer**: `fingerprint -> count, first, last, samples`.
  It keeps the first and the latest sample and one in between, not the first
  three (R-20). Formatting, `inspect` and scrubbing happen here, only for kept
  samples. A flood costs one upsert and at most three occurrence rows per
  fingerprint per 100 ms (10-15). A high-cardinality flood is a test (10-2).
- **One writer at a time**, on **its own one-connection pool**: a dynamic
  repo of the host's Repo (`repo.start_link(name: nil, pool_size: 1)`, then
  `put_dynamic_repo/1` in the writer), so the tracker never queues with a
  starving app at pool exhaustion (05-42, R-12). Killed after 500 ms; failed
  batches merge back; backoff 50 ms to 5 s (08-30). A poison batch policy
  (counts only after 3 failures, drop and count after 6) is design, tested in
  step 1 (R-18).
- **Store attachment**: `{Blackbox, repo: Charta.Repo, build: ...}` in the
  host's tree, right after the Repo, starts the pool and the writer. Until it
  is up, events wait in the buffer (capture started with `:blackbox`). It
  traps exits and **flushes on stop** (it stops before the Repo, children
  stop in reverse order), with a deadline under the shutdown timeout.
- **Spool**: what the buffer still holds when `:blackbox` itself stops (the
  Repo was the failure, or the flush missed its deadline) is written to one
  file in a configured directory (1charta: the data volume) and imported on
  the next boot. So the cascade before a `start_permanent` halt, and a
  deploy's last batch, survive (R-3).
- **No recursion**: the lib's own processes carry `blackbox: true` Logger
  metadata and its own events the `[:blackbox]` domain; `log/2` drops both
  first, and a process-dictionary flag stops re-entry (04-64). Every handler
  and filter body is in `catch kind, reason` with a counter.
- **Lost is shown, not hidden**: captured, deduped, dropped, handler errors,
  writer failures, in flight, spooled, and `logger_proxy` drop-mode notices
  ("crash reports lost: unknown") are on the page and in the API.

### 7. Storage

- The host's own Postgres: `blackbox_issues` (fingerprint unique, type,
  title, state, count, first/last seen with build, the builds seen, resolved
  and muted fields) and `blackbox_occurrences` (issue_id, the wide columns
  above, `payload jsonb`, at). Upsert by fingerprint.
- Migrations are versioned functions in the lib; `mix blackbox.gen.migration`
  writes the host's migration file (ErrorTracker's and Oban's pattern).
- Retention: the last 100 occurrences per issue and 30 days, never the issue
  row; the pruner runs on the writer's pool and keeps up with a hot
  fingerprint's ~30 rows/s.
- `grouping_version` is stored; a later version regroups only new
  occurrences, and the page shows both.

### 8. The page and the agents

- **The page** is a Plug that renders server-side HTML with a few lines of
  plain JS, mounted by the host: `forward "/_blackbox", Blackbox.Plug,
  authorize: fun`. No LiveView, no Hologram. Two views:
  - **Inbox**: one list by state and recency (new and regressed first),
    count, first and last seen with build; the counters of expected errors
    and of the lib's own losses at the foot.
  - **Issue**: header with state and actions (resolve in build, mute, note);
    the recommended occurrence (the one with the most context); then **one
    timeline** with relative time in the first column ("-3.2 s"): the trail,
    the causal chain (request -> Task -> GenServer call), the crash, what the
    supervisor did after, the system snapshot; then locals, the stack
    (in-app open, deps folded), the request.
- **The API**, same Plug: `GET /issues?state=&since_build=&source=`,
  `GET /issues/:id` (JSON), `GET /issues/:id.md` (issue, recommended
  occurrence, timeline as Markdown), `POST /issues/:id/resolve {build}`,
  `/mute`, `/note`. Versioned JSON.
- **Security** (R-10, R-11):
  - `authorize` is required; the Plug refuses to mount without it.
  - State-changing routes need a custom `x-blackbox` header, which a
    cross-site form cannot send and a cross-origin fetch cannot without a
    preflight the Plug refuses; the page's JS sends it. No cookie auth.
  - "Localhost only" also checks the `Host` header (DNS rebinding).
  - All event text is HTML-escaped; the page sends its own strict CSP.
  - In Markdown, event text sits inside a fence longer than the longest
    backtick run in it, after a line saying it is data, not instructions.
  - **Browser events are an ingest** anyone with a board link can write to
    (`/tab/error`): they are marked `source: browser` and untrusted in the
    Markdown, and left out of the default agent listing (`source=browser`
    includes them). Server-side capture has no ingest at all, and the
    tracker never starts an agent or runs a fix (report 03, VU#212479).
- **A quotable id**: `Blackbox.current_ref/0` for error pages and JSON
  errors.

### 9. How 1charta wires it in

1. `mix.exs`: `{:blackbox, git: ...}` until the hex release (a path dep to
   a sibling checkout only on a developer's machine, never in the
   Dockerfile); `reloadable_apps: [:charta, :blackbox]` in `config/dev.exs`
   while it is a path dep.
2. `{Blackbox, repo: Charta.Repo, build: Charta.build()}` right after
   `Charta.Repo` in `Charta.Application`; the migration; `spool_dir` and
   `ERL_CRASH_DUMP` on the data volume in `deploy/compose.yaml`.
3. Scrub config: `filter_parameters` (already has `key`), `/b/<id>` and
   Space link paths, `?key=`.
4. `format_status/1` on `Charta.Board.Server` and `Charta.Note.Server` that
   summarises `state`, `message` and `log`: board id, op kinds and counts,
   tab count; never text, titles or chat (`{:say, from, text}`, `{:apply,
   ops, ...}`; `board/server.ex:61, 162`).
5. `ref` on `ChartaWeb.ErrorHTML` ("1charta had trouble. Reference a1b2c3.")
   and `ErrorJSON`.
6. `/tab/error` also calls `Blackbox.capture_browser/2` with `{name,
   message, stack, url}` only, never the posted `key`; the sealed-board rule
   stays (only same-origin frames, no message).
7. `Blackbox.capture_exception` at the three warning rescues
   (`board/server.ex:441, 482`, `notes.ex:935`).
8. Hologram commands: `Blackbox.set_context(%{hologram: {module, name}})` in
   a Hologram middleware, which runs just before `module.command/3`
   (`deps/hologram/lib/hologram/controller.ex:340, 355`), so commands do not
   all group under `/hologram/command` (R-30). Never called from actions.
9. Mount the page at `/_blackbox`: localhost with a `Host` check in dev; in
   prod Basic auth with `BLACKBOX_TOKEN` for a person, the same token as a
   Bearer header for an agent. Coding agents may read prod errors (the user
   decided so on 2026-10-03): the token and the URL go into the agent's
   environment as `BLACKBOX_URL` and `BLACKBOX_TOKEN`, read-only routes
   first; resolve, mute and note stay with a person until the agent has
   earned them.

Found along the way, fixed separately in 1charta (not the lib): the
`rescue Postgrex.Error -> {:error, :taken}` at `spaces.ex:847, 1096` should
match `unique_violation` only, as `participants.ex:127` does
(`docs/ideas/a-db-outage-is-not-a-taken-name.md`).

### 10. Not built, on purpose

Session replay, AI merging of similar issues, grouping rule languages,
suspect commits, dashboards and performance monitoring (APM is another
tool), built-in Slack or email, public ingest, agents that fix on their own,
always-on call or exception tracing, an ETS or GenServer crumb store.

### 11. Later, after 1charta has lived with v1 for a few weeks

Each has its lab evidence ready; none is needed for 1charta today:

- **The `seq_trace` label** for casts, sends and orphaned work: the label is
  the request's pid (a live request needs no table), the handler clears its
  token around its own `send` so the lib's writer and the DB pool never adopt
  one (10-9a), and the finished-trail table is proven before it is built.
- **The OTP 28 system-monitor session** (`trace:system/3`: long_gc,
  large_heap, long_message_queue; 06-32, 06-39) into a node ring.
- **Crash-dump import** on boot (the header only; `ERL_CRASH_DUMP` is set
  already).
- **Escalating** against an hourly baseline, and an `on_issue` callback.
- **Cowboy, LiveView, channels and Oban** attachments, with lab 05's 65 cases
  as fixtures; Cowboy's cross-process dedupe must pair sightings, not
  suppress equal failures of different requests (R-6).
- **On demand**: `Blackbox.watch/2` (`:sys.log`, +56 ns a call),
  "record this process for 60 s" (a receive-trace session), "trace swallowed
  errors for 30 s" (`erlang:error/throw` call trace, rate limited; 04-51),
  `Blackbox.monitor/1` for chosen unsupervised processes.
- **Dev issue files** (`tmp/blackbox/*.md`; agents can `curl` the `.md`
  route meanwhile), a `Blackbox.Store` behaviour, forwarders to
  Sentry-compatible or OTLP endpoints, an MCP wrapper over the API.

### Steps

Each step lands with its tests first; the lab suites are ported as the lib's
spec. The lib's tests set `backtrace_depth` and the primary filter
explicitly, run with `max_cases: 1` for anything global, and assert bounds,
not exact counts, for anything through `:logger_proxy` (04 rec. 10).

1. **Port the spike** into this repo with the 1charta wiring of
   9.1: the own application, the install sequence (primary filter, handler at
   `:all`, telemetry, watchdog with pause and give-up), normalizer, dedupe by
   source, fingerprint v1, the pipeline (admission, buffer, own pool, flush,
   spool), the Postgres store (tables, upsert, derived regression,
   retention, migration generator). Tests first:
   - lab 08's safety suite; its SASL tests (08-7, 08-34..36) rewritten for
     the primary filter (they used the translator route, R-4);
   - a console test: the default handler's output to a file, byte-compared
     with and without Blackbox;
   - mutations M2, M7 and M11 must now turn a test red (a new anonymous
     function in the same function, in-app vs dependency frames, the ring
     bound); empty-stack and no-in-app-frame fingerprints;
   - a real repeat in one process within 1 s counts (10-1); a
     high-cardinality log flood groups by call site (10-2);
   - reductions budgets; a crash with a 1 MB state measured;
   - boot: a crash in a child started before the Repo is stored once the
     store attaches; stop: events in the buffer are in the database or the
     spool after `Application.stop(:charta)`;
   - lab 04's failure table as one test per row (a row that says "0" must now
     say "1" where section 2 promises it).
   Check: `just blackbox-test` green three times; `mix release` in CI builds
   with the path dep.
2. **Before, scrubbing, page, 1charta**: the ring (binary caps, add-time
   scrubbing measured), per-request reset, the `$callers` and `client_info`
   joins, OTP report mining, the scrub table, the snapshot and the 1 s
   sampler; the page, the API and its security rules; `current_ref`,
   `capture_*`, `set_context`; 1charta 9.2 to 9.9. Tests first:
   - lab 06's joins and ring tests;
   - the secrets property test of section 5;
   - page tests: escaping, fence length, the `x-blackbox` header, the `Host`
     check, `authorize` required;
   - in 1charta: a raising Hologram command, a board server crash, a Task
     crash from a request and a browser error each appear once on
     `/_blackbox` with their trail, and none shows board text or a key.
3. **Later**: section 11, one item at a time, when 1charta asks for it.

## Consequences

- Every crash in 1charta, in a request or not, at boot or at shutdown, has
  one place to be seen, and it survives deploys. Supervisor restarts and
  give-ups, invisible today, show up.
- Each failure comes with its trail, its cause across processes (Tasks and
  calls; not casts yet), and the process's last message and state, scrubbed,
  without the app code changing.
- The price is measured and bounded: about 5 µs per request at p50, tens of
  µs per crash in the failing process (re-measured in step 1 at depth 32 and
  a 50-crumb ring), up to ~15 KB per process that logs, one extra database
  connection, two tables.
- The lib changes one global setting, `backtrace_depth`, and adds a primary
  filter that sees every log event (a domain match, then return). Both are
  switches. After a restart of Elixir's Logger app, SASL capture is blind for
  up to 5 s until the watchdog re-adds the filter.
- **Still invisible**, and said so on the page: unsupervised processes that
  `exit` or are killed; swallowed exceptions; casts not joined to their
  request; NIF crashes and OOM kills (the OS kills the VM, no dump);
  `halt` from code; port exits to trapping owners; os_mon alarms; browser
  errors outside boards; a burst of plain `spawn` crashes, which the VM drops
  before any handler (the page shows the drop-mode notice instead of
  pretending).
- A second repository: 1charta's CI fetches it as a git dependency until the
  hex release.

## Answers (2026-10-03)

1. **The name is `blackbox`.** Module `Blackbox`, package `blackbox`. The hex
   placeholder is not published yet; it is an outward step for a later "do
   it".
2. **Coding agents may read prod errors** through the API behind
   `BLACKBOX_TOKEN` (section 9.9).
3. **Order of section 11**, decided by the lead: first the **OTP 28
   system-monitor session** (1charta's own failure modes are mailbox growth
   on board servers and `max_heap_size` kills of SSE processes, which only
   `long_message_queue` and `large_heap` can show before the kill), then the
   **`seq_trace` label** (board ops arrive as casts, so the join is worth
   its cost once the leak fix of section 11 is proven), then
   `Blackbox.monitor/1`, then the rest as 1charta asks.
