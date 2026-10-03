# 01 sentry-elixir, deep source read

Agent 01, 2026-09-27. sentry-elixir **13.5.1** (latest tag) and **main**
(`edb3ecf`, heading for 14.0), source read plus a 27-test lab
(`lab/01-sentry/`, Elixir 1.20.4 / OTP 28, Bandit 1.12) plus all 457 GitHub
issues.

## Summary for the lead

1. **Sentry's logger handler is off by default** (13.5.1: `enable_logs:
   false`; main: `logs: nil`): out of the box a crashing GenServer, Task or
   process is **not reported** (lab 01-1; issue #1047 "enable by default"
   still open). Only PlugCapture/manual/Oban calls report.
2. **Phoenix on Bandit, set up as the docs say, loses controller 500s**
   (lab 01-3): no PlugCapture ("Cowboy only") + hand-attached handler that
   excludes the `:bandit` domain. The two handler defaults disagree
   (`[:cowboy]` vs `[:cowboy, :bandit]`) after 5 flips since 2024.
3. **Duplicates are fought by excluding log domains, not by identity**:
   PlugCapture + handler send the same failure twice and `Sentry.Dedupe`
   misses it, because it hashes the whole event incl. extra/request
   (lab 01-5; issues #353, #486, #535, #736, #1045, #895).
4. **Dedupe is a silent sliding window**: an identical error recurring
   within 30 s is dropped forever, with no count (lab 01-6, 01-7).
5. **GenServer crash events carry neither last message nor state**: the
   parsing exists but only for non-exception exits; the common `raise`
   path skips it (lab 01-2a, red on first run). The "what happened before"
   data OTP hands over is discarded.
6. **Some failures leave no log at all, so no handler can see them**:
   `init/1` raise under `GenServer.start`, bare `spawn` exits, linked
   Task callers, and every **supervisor report** (Elixir's primary
   `logger_translator` filter has `sasl: false`, `logger/utils.ex:12-13`)
   (lab 01-2i/l/n/o/p). A complete tracker needs more than a handler.
7. **Breadcrumbs are manual** (only the LiveView hook adds any), second
   resolution, stored in Logger process metadata; context crosses
   processes only via a `$callers` walk and only for handler events
   (lab 01-8a/b/c).
8. **Grouping is left to the server**; the one client fingerprint
   (GenServer call timeout) embeds call args and floods (#933 open); Oban
   grouping is bad (#936 open). We need a client-side, line-shift-proof
   fingerprint.
9. **The app pays**: event built in the crashing process (median 52-62 µs
   per crash); with a slow Sentry the handler switches the *app process*
   to synchronous HTTP (17 of 300 calls blocked >= 50 ms, lab 01-9);
   Sentry down = 1+2+4+8 s retry sleeps per event, unbounded mailboxes
   (#932 open); on main the overload switch reads a counter nothing
   increments any more.
10. **Copy**: logger handler as base + `try` around backends, `:sentry`
    domain anti-recursion, `$callers` context, telemetry-handler-failure
    and Oban integrations, the scrubber defaults, guarded user callbacks.
    **Do better**: attach at boot; one normalised failure record merged
    from logger + telemetry by identity; OTP crash reports parsed as terms
    (last message, state, queue, label); supervisor reports and silent
    failures captured; automatic µs breadcrumbs; bounded non-blocking
    pipeline into the app's Postgres; counts for everything dropped.

## 1. Versions read

- Clone: `scratchpad/src/sentry-elixir` (github.com/getsentry/sentry-elixir).
- **Latest release tag `13.5.1`** = commit `ac8f14e` (2026-09-02).
- **main** = commit `edb3ecf` (2026-09-24), 33 commits after 13.5.1, heading
  for a breaking **14.0** (`docs: add 13.x to 14.x upgrade guide (#1231)`,
  `feat(scrubber)!: replace redacted values with [Filtered] (#1227)`,
  `refactor(config): remove enable_logs toggle (#1186)`). 29 files in `lib/`
  changed, +1822/-699. `lib/` is 28,334 lines in total on main.
- Local toolchain for the lab: Elixir 1.20.4 on OTP 28.
- Line refs below are to **main** unless marked `@13.5.1`.

## 2. Capture surface: `Sentry.LoggerHandler` (read)

**It is not attached by default.** This is the single most important fact.
- @13.5.1: `Sentry.Application.maybe_add_logger_handler/0` attaches
  `:sentry_log_handler` only `if Config.enable_logs?()`, and
  `enable_logs` defaults to `false` (`config.ex@13.5.1:424-426`).
- main: `enable_logs` is gone; the handler is attached only when the
  `:logs` option is non-nil, and `:logs` defaults to `nil`
  (`application.ex` `maybe_add_logger_handler/0`; `config.ex:598-605`
  "When this is `nil` (the default), the handler is not attached at all").
- So an out-of-the-box Sentry install reports only what `PlugCapture`
  (if added to the endpoint), `Sentry.capture_*` calls, and the opt-in
  Oban/Quantum/telemetry integrations send. **A crashing GenServer, Task,
  or `spawn`ed process is silent unless the user adds the handler by hand
  or turns on logs.** The docs say so, but in a `.tip` box
  (`logger_handler.ex` moduledoc).

**What the handler does per log event** (`logger_handler.ex` `log/2` ->
`ErrorBackend.handle_event/3`, `logger_handler/error_backend.ex:17-49`):
1. drop if level < `capture_level` (default `:error`);
2. drop if the domain contains `:sentry` (anti-recursion, always) or is in
   `capture_excluded_domains` (default `[:cowboy, :bandit]`: "avoids
   double-reporting events from `Sentry.PlugCapture`");
3. drop if the handler's `RateLimiter` says so (opt-in, `rate_limiting:
   [max_events:, interval:]`, default `nil` = off);
4. drop if `discard_threshold` is set and the sender queue is at it;
5. else build options and call `Sentry.capture_exception/2` or
   `capture_message/2` **inside the logging process** (handlers run in the
   caller; the code comment at `error_backend.ex:37-38` relies on that to
   read the process's Sentry context from the process dictionary).
6. `log/2` wraps each backend in `try ... rescue _ -> :ok`
   (`logger_handler.ex:468` `log/2`) so a bug in Sentry's parsing cannot get
   the handler removed by `:logger`. Note: `rescue` only, not `catch`, so a
   `throw` or `exit` inside it would still escape to `:logger` (which then
   removes the handler).

**What counts as a "crash"** (`error_backend.ex:54-180`). Crash detection is
shape matching, not a list of OTP report kinds:
- `msg: {:string, _}` or `{format, args}`: reported only if
  `meta[:crash_reason]` is `{exception, stacktrace}` (-> exception event,
  `handled: false`) or `{reason, stacktrace}` with a list stacktrace
  (-> message event `** (stop) ...`, `extra.crash_reason`), plus special
  fingerprint `[type, "genserver_call", inspect(call)]` for
  `{:noproc | :timeout, {GenServer, :call, _}}` exits.
  Anything else is dropped unless `capture_log_messages: true`.
- `msg: {:report, map}`: reported if the report has `reason: {exception,
  stack}` / `reason: {reason, stack}` / `reason: reason`; Ranch listener
  format strings are special-cased (OTP 25 only, per a TODO); a
  `%{label: {_, _}, report: list}` clause digs `:error_info` out for
  pre-1.15 init crashes. Every other report is dropped unless
  `capture_log_messages`.
- `msg: {:report, %{elixir_translation: chardata}}` (Elixir 1.19+ puts the
  translated text inside the report) is converted back to a string first.
- GenServer "last message" and "state" are recovered by **pattern-matching
  the translated chardata** of Elixir's `Logger.Translator` output
  (`extra_info_from_message/1`, three `try_to_parse_message_or_just_report_it`
  clauses for three historical layouts). They end up as `inspect`ed
  strings in `extra`, not as terms. Brittle: any change in Elixir's
  translator text silently loses them (falls through to a plain message).
- `Logger.error("oops")` with no crash reason: **dropped** unless
  `capture_log_messages: true`. `Logger.warning` never (capture_level).

**Context propagation across processes** (`logger_utils.ex`
`build_sentry_options/5`, `get_sentry_options_from_callers/1`): the
`:sentry` key of logger metadata; if absent, it walks `meta[:callers]`
(`$callers`) and reads each caller's **process dictionary** with
`:erlang.process_info(caller, :dictionary)` (local node only) to find
`$logger_metadata$`'s Sentry key. `$ancestors` is not used. Reading a whole
foreign process dictionary per event is O(dict size) and races with the
caller exiting (then it just finds nothing).

**Rate limiter** (`logger_handler/rate_limiter.ex`): one `:atomics`
counter per handler in `:persistent_term`, reset to 0 every `interval` ms by
a GenServer tick. Fixed window, global (not per fingerprint): one noisy
error can starve every other error for the window. Opt-in.

**Overload** (`error_backend.ex:398-415`): default `sync_threshold: 100`:
when 100+ events are queued in the sender pool, the *logging process* is
made to send synchronously (blocks the crashing process on HTTP). The
alternative `discard_threshold` drops instead. Both read one global
`SenderPool.get_queued_events_counter()`.

**Structured logs** (`LogsBackend`): separate feature, ships log lines to
Sentry's Logs product; not breadcrumbs, not linked to the error event except
by trace id.

**Also** `Sentry.LoggerBackend` (old Elixir `Logger` backend, runs in its
own process) still ships (`logger_backend.ex`).

**Bandit and the excluded `:bandit` domain: five flips in two years.**
Bandit logs a request exception with `Logger.error(..., domain: [:bandit],
crash_reason: {reason, stack}, conn: conn, plug: ...)`
(`deps/bandit/lib/bandit/logger.ex:47-60`, `pipeline.ex:235-239`, bandit
1.12.5 in 1charta's lock) and fires `[:bandit, :request, :exception]`
telemetry. Sentry's handling, from `git log -S":bandit]"`:
`c4b2fac` 2024-06-24 add `:bandit` to excluded (#739) -> `d571a6c`
2025-05-29 remove it, "recommend PlugCapture only for Cowboy" (#900) ->
`752f218` 2026-06-02 exclude again (#1073) -> `62d56a0` 2026-07-03 revert
(#1099) -> `676e43c` 2026-07-06 remove from the `:logs` config default
(#1102). Today (13.5.1 and main) the two defaults **disagree**: the
auto-attached handler (`config.ex:285-287`) excludes `[:cowboy]`, but a
hand-attached `Sentry.LoggerHandler` (the way the moduledoc teaches)
excludes `[:cowboy, :bandit]` (`logger_handler.ex:41-44`). And the
Phoenix guide says: on Bandit do **not** use `PlugCapture`
(`plug_capture.ex:9-13`, `pages/setup-with-plug-and-phoenix.md`; the
Igniter installer only adds it if `:plug_cowboy` is a dep,
`mix/tasks/sentry.install.ex:147-160`). Read together: a Phoenix-on-Bandit
app that follows the moduledoc (manual handler) and the guide (no
PlugCapture) **loses every controller exception**. Proved in the lab (01-3).

## 3. `PlugCapture`, `PlugContext`, LiveView (read)

`Sentry.PlugCapture` (`plug_capture.ex`, `__before_compile__`) overrides the
endpoint's `call/2` with `try super(conn, opts) rescue/catch`, reports, and
re-raises the original. `Plug.Conn.WrapperError` is unwrapped. `throw`/`exit`
become a message "Uncaught #{kind} - #{inspect(reason)}". Every capture runs
through `Sentry.Callback.guard/2` so a crashing scrubber or reporter cannot
replace the app's exception (main added this in #1223). Scrubbing guesses:
only `Phoenix.ActionClauseError` args are scrubbed of the conn.
It sees only exceptions that bubble out of the endpoint in the request
process: not a Task spawned by the controller, not a linked process that
kills the request. (Phoenix's `Plug.ErrorHandler` renders the error page
and re-raises, so exceptions do bubble out of the endpoint.)
Expected exceptions (404 `NoRouteError`, `plug_status` < 500) are **not**
filtered by PlugCapture itself; they are filtered later by
`Sentry.DefaultEventFilter` (see 7).

`Sentry.PlugContext` (`plug_context.ex` `call/2`) runs on **every request**
(placed after `Plug.Parsers`): fetches cookies and query params, runs the
scrubbers, builds the full request map (url, method, scrubbed params,
cookies, all headers, env with REMOTE_ADDR, request id) and stores it in
Logger process metadata via `Sentry.Context.set_request_context/1`. The
cost is paid on every request whether or not it fails (not measured by
Sentry; our lab 06 measures the analogous cost). An exception raised
*before* `Plug.Parsers` (a body parse error) has no request context.

`Sentry.LiveViewHook` (`live_view_hook.ex:103-260`): `on_mount` that sets
request/user context and **attaches hooks on `handle_params`,
`handle_event`, `handle_info`**, each adding a breadcrumb (categories
`web.live_view.mount|params|event|info`, data scrubbed). These are the
**only automatic breadcrumbs in the whole SDK** (grep of `add_breadcrumb`
in `lib/`). LiveView crashes themselves reach Sentry only via the logger
handler (the LiveView process dies with a crash report).

## 4. Oban, Quantum, Telemetry integrations (read)

- `Integrations.Oban.ErrorReporter` (`integrations/oban/error_reporter.ex`):
  attaches `[:oban, :job, :exception]` when `integrations: [oban:
  [capture_errors: true]]`. Reports **every failed attempt** (no "only the
  last attempt" default; there is a `should_report_error_callback` since
  13.x). Fingerprint `[job.worker, "{{ default }}"]`; tags worker, queue,
  state; `extra` = args (scrubbed), attempt, id, max_attempts, meta, tags.
  `{:error, reason}` returns arrive as `Oban.PerformError` and are
  unwrapped when the inner reason is an exception. Empty stacktraces get a
  fake frame `{Worker, :process, 1, []}`.
- `Integrations.Oban.Cron` and `Integrations.Quantum.Cron`: cron
  **check-ins** (monitors: job started/ok/error), not error capture.
- `Integrations.Telemetry` (`integrations/telemetry.ex`, opt-in
  `report_handler_failures`): attaches `[:telemetry, :handler, :failure]`,
  so a crashing telemetry handler (which telemetry detaches silently) is
  reported. Good idea, we copy it and default it on.
- No Ecto, Req/Finch, Phoenix channel, or `[:phoenix, :router_dispatch,
  :exception]` / `[:bandit, :request, :exception]` telemetry is used for
  **errors**. (Tracing uses OpenTelemetry instrumentation libs, see 9.)

## 5. Context and breadcrumbs (read)

`Sentry.Context` (`context.ex`): all context (user, tags, extra, request,
breadcrumbs, attachments) is one map under key `:__sentry__` in **Logger
process metadata** (`:logger.update_process_metadata/1`), i.e. the process
dictionary. Consequences:
- per process, gone when the process dies; a Task started from a request
  sees the parent's context only through the `$callers` walk in the handler
  (section 2), and only for handler-captured events, not for a
  `Sentry.capture_exception` call inside the Task;
- `add_breadcrumb/1`: prepends and `Enum.take(max_breadcrumbs)` (default
  100) on **every add** (O(n) copy per breadcrumb), timestamps in **whole
  seconds** (`System.system_time(:second)`), so ordering inside a second is
  lost in the UI;
- breadcrumbs are **manual** except LiveViewHook's. No automatic Logger
  breadcrumbs (Sentry's JS/Python SDKs turn log lines into breadcrumbs;
  Elixir does not), no HTTP client, Ecto query, or telemetry breadcrumbs.
  The newer "structured logs" product ships logs separately and links them
  only by trace id.

## 6. Event building, stacktrace, source context (read)

`Sentry.Event.create_event/1` (`event.ex:195-260`) runs **in the capturing
process** (for the handler: the crashing process, inside `:logger`'s call):
merges config/context/opts, UUID, ISO timestamp (µs), `contexts` = only
`os` + `runtime` (Elixir build) + optional OTel `trace`
(`event.ex:489-507`), `modules` = all loaded app versions (cached in
`persistent_term` at boot), `server_name`, release, environment.
**Not captured:** pid, registered name, process label, `$ancestors`, the
supervisor, mailbox length, memory, reductions, node health (run queue,
process count, memory), the OTP crash report's `dictionary`/`links`/
`message_queue_len` (those fields are in the `proc_lib` crash report but
the handler only looks at `reason`).
Stacktrace: every frame becomes `module`, `function` (`Mod.fun/arity`),
`filename`, `lineno`, `in_app` (module prefix allow-list from
`in_app_module_allow_list` + `in_app_otp_apps`), `vars` = inspected args
when the frame has args (only the top frame of a `FunctionClauseError`
carries them). Depth = whatever the VM gave (default `backtrace_depth` 8);
Sentry does not raise it.
Source context: opt-in `enable_source_code_context: true` plus
`mix sentry.package_source_code` at build time, which reads
`root_source_code_paths` (excluding `_build/ deps/ priv/ test/`), and
writes `term_to_binary(compressed: 9)` to **`priv/sentry.map` inside the
sentry dep** (`sources.ex` `path_of_packaged_source_code/0`); at boot
`Sentry.Sources` loads it into ETS. `context_lines` default 3. Forget to
rerun the task and you ship stale lines silently.

## 7. Fingerprint, dedupe, filtering, sampling (read)

- **Fingerprint** default `["{{ default }}"]` (`options.ex:153-159`): the
  SDK leaves grouping to the Sentry **server**. Client-side fingerprints
  exist only for GenServer call timeouts/noproc
  (`["timeout"|"noproc", "genserver_call", inspect(call)]`; note
  `inspect(call)` includes the call's arguments, so every distinct
  argument makes a new issue) and Oban (`[worker, "{{ default }}"]`).
- **Dedupe** (`dedupe.ex`, on by default `dedup_events: true`):
  `phash2` of `[exception, message, level, fingerprint, user, tags, extra,
  breadcrumbs, request, attachments]` (`event.ex:518-531`) in a public ETS
  set; `insert/1` **refreshes the timestamp on every hit**
  (`:ets.update_element`) and a sweep every 10 s deletes entries not seen
  for 30 s. Two consequences: (a) an identical error that keeps recurring
  at least every 30 s is reported **once and then never again** while it
  continues (sliding window, only a debug log line per drop, no counter
  sent); (b) because `extra` (which carries `logger_metadata`,
  `logger_level`, `crash_reason`) and `request` are hashed, the *same*
  failure seen by PlugCapture and by the logger handler hashes differently
  and is **not** deduped (the reason for the domain exclusion dance).
  Proved in the lab (a: 01-6, 01-7; b: 01-5).
- **DefaultEventFilter** (`default_event_filter.ex`): drops, **only when
  the event source is `:plug`**, `Phoenix.NotAcceptableError`,
  `Phoenix.Router.NoRouteError`, `Plug.Conn.InvalidQueryError`,
  `Plug.Parsers.{BadEncodingError, ParseError, RequestTooLargeError,
  UnsupportedMediaTypeError}`, `Plug.Static.InvalidPathError`, and
  `FunctionClauseError` in a router's `do_match/4`. A hard-coded list, not
  `Plug.Exception.status/1 < 500`, so any other 4xx exception with a
  `plug_status` (e.g. `Ecto.NoResultsError` -> 404,
  `Phoenix.ActionClauseError` -> 400) **is reported** as an error. Plus the
  `before_send` callback.
- **Sampling**: `sample_rate` (default 1.0) uniform random per event;
  unsampled events are counted in a client report.
- Order in `Client.send_event/2`: `before_send` -> DSN check -> sample ->
  dedupe -> send (`client.ex` `send_event/2`).

## 8. Transport, overload, Sentry down (read)

- @13.5.1 errors: `Transport.Sender.send_async/2` casts to one of
  `max(schedulers, 8)` sender GenServers (unbounded mailboxes) and bumps a
  global `:counters` queue gauge. Each sender POSTs with retries sleeping
  **1 s, 2 s, 4 s, 8 s** (`transport.ex` `@default_retries`) inside the
  sender, so when Sentry is down each event occupies a sender for 15 s and
  is then dropped (`ClientReport` "send_error"). 8 senders -> about 0.5
  events/s throughput while down; everything else queues in RAM.
- The handler's `sync_threshold: 100` then makes the **crashing process
  itself** send synchronously (with the same sleeps), i.e. under a flood
  while Sentry is slow, application processes block for up to 15 s each.
- main (14.0-to-be): errors go through `Sentry.TelemetryProcessor` by
  default (`telemetry_processor_categories` default changed from `[]` to
  `[:error, :check_in, :transaction]`, #1208): a per-category ring buffer
  GenServer (error capacity **100**, "oldest items are dropped") fed by
  `GenServer.cast`, a weighted scheduler, a transport queue of 1000. That
  path never touches `SenderPool`'s counter, so the handler's
  `sync_threshold`/`discard_threshold` (which read that counter,
  `error_backend.ex:33,410`) **no longer do anything for errors on main**.
- Server-side rate limits (`429`, `X-Sentry-Rate-Limits`) are honoured per
  category; drops are counted and sent as client reports.
- Nothing is persisted: node restart = queued events lost. No disk spool.
- Handler runs in the logging process: event building (inspect of state,
  args, scrubbing, JSON sanitising) is paid by the crashing process, and
  the `:logger` handler call holds nothing global, so this is safe from a
  logger-overload point of view but costs the caller.

## 9. Test mode, tracing, OpenTelemetry (read)

- `Sentry.Test` (`test.ex`, 1081 lines on main): per-test collection via
  `before_send` into an ETS table owned through `NimbleOwnership`, a Bypass
  HTTP server as fake DSN, `allow_sentry_reports/2` to let other pids report
  into a test. Needs `bypass` as a test dep since 13.0. Our lab did not use
  it: `before_send`/`after_send_event` callbacks that forward to a
  registered pid plus a fake `Sentry.HTTPClient` were enough and show both
  "captured" (before dedupe) and "sent" (after dedupe).
- Tracing (`lib/sentry/opentelemetry/*`): Sentry is an OpenTelemetry **span
  processor + sampler + propagator**; spans come from the
  `opentelemetry_phoenix/bandit/ecto` instrumentation libs, not from Sentry.
  Errors get `contexts.trace` only when the capturing process has an active
  OTel span (`event.ex:503-506`); a crash in a Task that did not inherit
  the OTel context is not linked (the docs say so). 13.5.0 fixed
  cross-node parents and spans outliving their parent.
- Metrics (main): runtime gauges (memory, run queue, process/atom/port
  counts, scheduler utilisation) via `telemetry_poller`, sent as metrics,
  **not attached to error events**.
- Build: sentry 13.5.1 compiles with 3 type warnings on Elixir 1.20.4
  (`metrics.ex:120`, `event.ex:505`: clauses the checker proves unreachable
  when OTel is absent). Cosmetic.

## 10. Lab: what sentry 13.5.1 really catches (verified)

`lab/01-sentry/` (sentry 13.5.1 from hex, bandit 1.12.x, Elixir 1.20.4 /
OTP 28, Apple M3 Pro). Collector: `before_send` and
`after_send_event` forward events to the test process; a fake HTTP client
answers 200 (optionally slow). 27 tests, 3 runs green, seeds in
`logs/01-sentry.log` (final: 27 tests, seeds 899688, 679913, 175623, all
green). Handler attached by hand
(`:logger.add_handler(:lab_sentry, Sentry.LoggerHandler, %{config: ...})`)
unless the test says otherwise.

Headline results:
1. Out of the box (no `:logs`), a GenServer crash is **not reported** (01-1).
2. With the handler, raises in GenServer, Task, and bare `spawn` are
   reported; `exit`/`throw` in a Task are reported as messages (01-2b..e).
3. **GenServer crash events carry neither the last message nor the state**
   (01-2a, first run red). The parsing code for them exists but only runs
   for non-exception exit reasons; the common case (a `raise` in a
   callback) skips it. The data that answers "what happened before" is in
   the crash report and is thrown away.
4. A process started with bare `spawn` that exits (not raises) is invisible
   to every logger handler: the VM logs nothing (01-2i, first run red).
   Only a monitor/link or a trace sees it. The same exit in a `Task` is
   reported (01-2k), with a fingerprint that embeds the call's arguments.
5. **Phoenix-on-Bandit following the docs loses controller exceptions**
   (01-3): no PlugCapture (docs: Cowboy only) + hand-attached handler
   (excludes `:bandit`) = zero events for a 500. With the auto-attach
   default (`[:cowboy]`) the Bandit log line is reported, with request
   context from `PlugContext` (01-4).
6. PlugCapture + a handler that does not exclude `:bandit` sends the same
   failure **twice**; `Sentry.Dedupe` does not catch it because the two
   events hash differently (01-5).
7. A 404 exception (`plug_status: 404`) not in the hard-coded ignore list is
   reported as an error by PlugCapture (01-5b).
8. Dedupe drops an identical event, and the window slides: repeats keep it
   suppressed; only a pause longer than the TTL lets it through (01-6, 01-7).
9. Parent context reaches a crashed Task via `$callers` (01-8a) but not a
   manual `capture_message` inside the Task (01-8b). Breadcrumb timestamps
   are whole seconds (01-8c).
10. Handler cost in the crashing process: **median 52-62 µs per crash
    event** (build + enqueue, Apple M3 Pro); with a Sentry that takes 50 ms
    per POST, 17-18 of 300 crash logs **blocked the logging process for
    >= 50 ms** (sync mode after 100 queued, 01-9).
11. **Silent at the source** (no handler can fix these): an `init/1` raise
    under `GenServer.start` logs nothing on OTP 28, the error is only the
    return value (01-2l, first run red; sentry #542 from 2023 is still
    true); a supervised child whose `init/1` raises logs nothing either
    (01-2o) because **Elixir's primary `logger_translator` filter stops all
    SASL/supervisor reports** unless `handle_sasl_reports: true` (01-2p;
    Elixir 1.20.4 `lib/logger/lib/logger/utils.ex:12-13`). So supervisor
    restarts, start errors and max-intensity shutdowns never reach Sentry.
12. A `Task.async` crash awaited by another Task produces **one** event
    (the inner task); the linked caller dies by exit signal, which is not
    logged (01-2n, first run red). A `gen_statem` raise is reported (01-2m;
    sentry #485 was fixed).

### Claims table

| id | claim (as first written) | first run | final truth | test |
|---|---|---|---|---|
| 01-1 | default config: GenServer crash -> no event | green | no event | `01-1: with default Sentry config ...` |
| 01-2a | handler: GenServer cast raise -> event with last_message + state | **red** | event, but **no** last_message/state; extra = domain, logger_level, logger_metadata | `01-2a: ... WITHOUT last_message or state` |
| 01-2b | Task.start raise -> exception event | green | yes | `01-2b` |
| 01-2c | bare spawn raise -> exception event | green | yes (VM "Error in process" + crash_reason) | `01-2c` |
| 01-2d | Task exit(:boom) -> message event | green | yes, no exception interface | `01-2d` |
| 01-2e | Task throw -> event | green | yes | `01-2e` |
| 01-2f | Logger.error, no crash -> no event | green | no event | `01-2f` |
| 01-2g | capture_log_messages: error yes, warning no | green | as claimed | `01-2g` |
| 01-2h | supervised GenServer crash -> exactly 1 event | green | 1 (supervisor report not a second event) | `01-2h` |
| 01-2i | call timeout in bare spawn caller -> event w/ fingerprint | **red** | **no event**: VM logs nothing | `01-2i` |
| 01-2k | same in a Task caller -> message event, fingerprint `["timeout","genserver_call",":sleep"]` | green | yes | `01-2k` |
| 01-2j | rescued-and-swallowed -> no event | green | no event | `01-2j` |
| 01-2l | GenServer.start init raise -> 1 event | **red** | **no event, no log at all**; only `{:error, {exc, stack}}` return | `01-2l` |
| 01-2m | gen_statem raise -> 1 event | green | 1 event | `01-2m` |
| 01-2n | Task.async raise awaited in a Task -> 2 events | **red** | **1 event** (inner task); linked caller's death not logged | `01-2n` |
| 01-2o | supervised child init raise -> no event | green | no event, no log at all | `01-2o` |
| 01-2p | Elixir primary filter has `sasl: false` | green | yes: SASL/supervisor reports stopped before handlers | `01-2p` |
| 01-3 | Bandit, no PlugCapture, manual handler defaults -> 500 lost | green | lost | `01-3` |
| 01-4 | excluded [:cowboy] -> 1 event w/ request, domain [:bandit] | red (domain only) | 1 event, request.method GET, domain `[:elixir, :bandit]` | `01-4` |
| 01-5 | PlugCapture + handler -> 2 sent, hashes differ | green | as claimed | `01-5` |
| 01-5b | plug_status 404 exception -> reported | green | reported | `01-5b` |
| 01-6 | identical message twice -> 2 captured, 1 sent | green | as claimed | `01-6` |
| 01-7 | dedupe window slides on repeats | green | as claimed | `01-7` |
| 01-8a | parent tags reach crashed Task via $callers | green | yes | `01-8a` |
| 01-8b | manual capture in Task lacks parent tags | green | lacks them | `01-8b` |
| 01-8c | breadcrumb timestamps are integer seconds | green | yes | `01-8c` |
| 01-9 | slow Sentry: first 50 < 10 ms each, later calls block >= 50 ms | red (warm-up 11.3 ms) | median 56-62 µs; 17/300 calls >= 50 ms | `01-9` |

## 11. GitHub issues: what users say is missed, noisy, duplicated (read)

Source: GitHub search API, all **457 issues** of getsentry/sentry-elixir
(PRs excluded), fetched 2026-09-27; **11 open** (the maintainers close
aggressively). By year: 2016 50, 2017 66, 2018 39, 2019 29, 2020 31,
2021 26, 2022 22, 2023 45, 2024 67, 2025 47, 2026 32. Buckets by title
regex (approximate, they overlap): **missed 23**, **duplicate/noise/filter
30**, context/breadcrumbs/metadata 54, logger/handler/process 85,
plug/phoenix/server 48, oban/cron 21, stacktrace/source 23,
grouping/fingerprint 10, perf/overload/transport 28, tracing 39.

**Missed (not reported)**, the recurring shapes:
- process kinds the handler did not recognise: `gen_statem` crash reports
  ignored (#485, 2021, closed 2023), `GenServer.init/1` crashes not
  reported (#542, 2023), exit/throw not caught by PlugCapture (#446, fixed
  by adding `catch`), Phoenix channel errors (#93), exq workers (#337);
- the reporter itself dying: "Sentry not reporting errors because process
  gets killed" (#360): when capture runs in the failing process and that
  process is killed mid-send (e.g. a Task timeout or a supervisor
  shutdown), the event is gone;
- configuration traps: `:pid` in LoggerBackend metadata silently stops all
  sending (#520: unencodable metadata), a `URI` struct in LiveView context
  makes every LiveView event fail JSON encoding, "LiveView Hook silently
  swallows errors" (#1040, 2026), `excluded_domains` not working (#527);
- the default: **"Enable logging by default" (#1047, open)**, i.e. the
  handler is still opt-in (our 01-1).

**Duplicated / noisy**:
- same failure twice from Plug + logger: #353 (2019), #374, #486 (2021,
  "MatchError and Sentry.CrashError ... different contexts but describing
  the same error"), #535 (2023, "an exception was raised" twin with
  `capture_log_messages`), #736 (2024, Bandit error captured again by the
  handler with `original_exception: nil`, so `before_send` filters cannot
  catch it), #1045 (2026, auto handler + manual handler both active),
  #895 (2025, a user's deep dive: PlugCapture exists only because of 2019
  metadata gaps; Bandit runs the plug in the same process so the handler
  alone would do). This is the Bandit flip-flop of section 2 and our 01-5.
- grouping floods: **#933 (open)**: the client-side
  `[type, "genserver_call", inspect(call)]` fingerprint embeds call
  arguments (IDs), "we get flooded with individual error reports"; **#936
  (open)**: Oban errors group badly because Oban's `PerformError` message
  inspects the reason; #445: same type + stack, different message, grouped
  together; #837: Logger metadata should affect grouping (distinct
  `Logger.error` calls were dropped as duplicates).
- log floods from the SDK itself: #1179 (2026, "Failed to send Sentry
  event" several times per second when over quota), #271 (2018, same when
  offline).
- unbounded queues: **#932 (open)** "Sentry Concurrency Limits": with async
  sending, queues form in the hackney pool and in `Transport.Sender`
  mailboxes "which will eventually lead to an out of memory error".

**Context wanted** (most commented): #349 set context not included (13
comments, 4 reactions), #79 (2016!) "fallback to ancestor's context"
(`$ancestors`), #484 LiveView breadcrumbs, #137/#827 Logger metadata as
tags, #101 "GenServer/Task.Supervisor crash stacktrace is too vague" (only
`gen_server.erl` frames; needed ssh to see the real crash report),
#667/#666 status code and handled flag on the event.

**Safety**: #1219 (open, 2026-09-21): a table of every user callback
(`before_send`, `after_send_event`, filter, ...) and whether a crash in it
is handled: most were not; main fixed them in #1220-#1224 (section 1).

Reading: after 12 years the complaints are the same four: (1) a failure
kind is not caught, (2) the same failure arrives twice, (3) grouping splits
or merges wrongly, (4) the event lacks the context to understand it. All
four come from one design choice: Sentry has no single normalised failure
record on the client; each capture path builds its own event, and grouping
is delegated to the server.

## Findings table

| id | what | evidence | priority | proposal (one line) | size |
|---|---|---|---|---|---|
| F1 | Logger handler not attached by default; process crashes silent out of the box | `application.ex` `maybe_add_logger_handler`, `config.ex:598-605`; lab 01-1; issue #1047 open | P0 | blackbox attaches its handler at app start, always; opting out is the config | S |
| F2 | Two defaults for excluded domains (`[:cowboy]` auto vs `[:cowboy, :bandit]` manual), 5 flips since 2024 | `logger_handler.ex:41-44`, `config.ex:285-287`, git log -S; lab 01-3/01-4 | P0 | never exclude by domain; dedupe by failure identity instead (F6) | M |
| F3 | Bandit + docs-recommended setup loses controller exceptions | lab 01-3 | P0 | capture Bandit/Cowboy/Phoenix via both telemetry and logger, merge into one occurrence | M |
| F4 | GenServer crash events lack last message and state (exception path skips parsing) | `error_backend.ex:127-136` vs `182-216`; lab 01-2a | P0 | read `proc_lib`/`gen_server` crash report fields as terms (`last_message`, `state`, `client_info`, `dictionary`, `message_queue_len`), not translated text | M |
| F5 | SASL/supervisor reports never reach handlers (Elixir primary filter `sasl: false`) | Elixir `logger/utils.ex:12-13`; lab 01-2o/2p | P0 | our own **primary filter** (runs before Elixir's? order matters, lab 04/08) or a handler-level read of SASL domain with `handle_sasl_reports`; at least a supervisor-restart counter | M |
| F6 | Dedupe hashes the whole event incl. extra/request: same failure from two paths not merged, identical repeats suppressed forever (sliding window, no count) | `event.ex:518-531`, `dedupe.ex`; lab 01-5, 01-6, 01-7 | P0 | separate **issue fingerprint** (type + normalised in-app frames) from **occurrence id**; merge paths by (pid, reason hash, ~100 ms); count every occurrence, never drop silently | M |
| F7 | Grouping delegated to the server; client fingerprint for call timeouts embeds call args | `options.ex:153`, `error_backend.ex:151-160`; #933 open, #936 open, #445, #837 | P1 | client-side fingerprint: exception module + top N in-app `{m, f, arity}` (no line numbers, no args), message template with numbers/pids/refs masked | M |
| F8 | No automatic breadcrumbs (only LiveView hook); timestamps in seconds; O(n) per add | `context.ex` `add_breadcrumb`; grep; lab 01-8c | P0 | automatic breadcrumbs from Logger (all levels below error, cheap ring), telemetry spans (Plug, Ecto, Req/Finch, Oban), with monotonic µs timestamps; ring buffer | L |
| F9 | Context lives in the process dictionary; crossing processes only via `$callers` and only for handler events | `logger_utils.ex` `get_sentry_options_from_callers`; lab 01-8a/8b; issue #79 (2016) | P1 | propagate a request/job **trace id** in Logger metadata + `$callers`/`$ancestors`; link occurrences across processes by it | M |
| F10 | Event built in the crashing process (56 µs median) and under load the caller blocks on HTTP (sync_threshold) | `error_backend.ex:398-415`; lab 01-9 | P0 | handler copies a bounded raw term and returns; building, scrubbing, storing happen in our own bounded process; never block the caller | M |
| F11 | On main, sync/discard thresholds read a counter the new TelemetryProcessor path never increments | `sender_pool.ex`, `telemetry_processor.ex`, `error_backend.ex:33,410` | P2 | one bounded queue with one counter and a dropped-count that is itself stored | S |
| F12 | Sentry down: sender sleeps 1+2+4+8 s per event, then drops; unbounded mailboxes (#932 open) | `transport.ex` `@default_retries`, `sender.ex`; #932 | P1 | local Postgres storage (no network on the error path); drops counted | S |
| F13 | Init/1 crash under `GenServer.start`, bare `spawn` exits, linked callers: no log event at all | lab 01-2i, 01-2l, 01-2n | P1 | optional monitor/trace-based capture for named processes, plus a `Blackbox.report/2` for `{:error, _}` returns that matter | M |
| F14 | Expected-exception filter is a hard-coded list and only for `:plug` source | `default_event_filter.ex`; lab 01-5b | P1 | use `Plug.Exception.status/1` (< 500 = not an error, record as a counter) for every source | S |
| F15 | Source context needs a build-time mix task writing into the dep's priv | `sources.ex`; issues #362, #615, #638 | P2 | we run in the app: read source from disk in dev, embed in release with a compile-time manifest keyed by module, or store `{file, line}` only and let the UI read the repo | S |
| F16 | Callbacks crashing (before_send etc.) propagated to the app until #1220-1224 (main, unreleased) | issue #1219 open | P1 | every user callback runs under `try/catch kind, reason` with a counted fallback, from day one | S |
| F17 | Metadata that cannot be JSON-encoded silently kills events (`:pid` #520, `URI` #1040) | issues | P1 | store terms, not JSON: `inspect` with limits at capture, raw term in `term_to_binary` with size cap | S |

## Recommendations for the lib (what we copy, what we do better)

**Copy:**
1. A `:logger` handler as the base capture surface (it runs in the caller,
   sees crash reports with `crash_reason`), with every backend call wrapped
   so the handler is never removed (`logger_handler.ex:468` `log/2`); but use
   `catch kind, reason`, not only `rescue`.
2. The anti-recursion rule: everything the lib logs carries
   `domain: [:blackbox]` and the handler drops that domain first
   (`logger_utils.ex` `excluded_domain?/2`).
3. `$callers` lookup for context of Tasks (it works, 01-8a), extended to
   `$ancestors` and made cheap (read only our key, not the whole dict: we
   put the request id in Logger metadata, which Tasks do not inherit, so we
   also stamp it on the Task's metadata at spawn when possible).
4. The `[:telemetry, :handler, :failure]` integration, on by default.
5. Oban `[:oban, :job, :exception]` with worker/queue/attempt/args
   (scrubbed), but fingerprint by worker + exception + in-app frames, and
   record attempts as occurrences of one issue.
6. The scrubbing defaults of `PlugContext`/`Scrubber` (param denylist,
   cookies, authorization headers, `assigns` cleared, `private`
   allow-list). Main's `[Filtered]` marker is good UX: show that a value
   existed.
7. `Sentry.Callback.guard`-style wrapping for every user callback (main).
8. Client reports idea: count what was dropped and why, and show it.

**Do better:**
9. Attach at boot, no opt-in; one config key to disable (F1).
10. One normalised **failure record** per failure, built from whichever
    hooks saw it (logger crash report, Plug/Bandit/Phoenix telemetry
    exception, Oban telemetry, manual report), merged by a failure
    identity: `{pid, reason term hash}` within a short window, plus the
    request/job id. No domain exclusions (F2, F3, F6).
11. Parse OTP crash reports as **terms** (`msg: {:report, %{label:
    {:proc_lib, :crash}, report: [...]}}` and `gen_server`'s
    `%{label: {:gen_server, :terminate}, last_message:, state:, ...}`)
    before Elixir's translator turns them into text; keep last message,
    state (bounded inspect), `message_queue_len`, `links`, `dictionary`
    keys, `$initial_call`, process label (F4).
12. Make supervisor reports visible: restarts and max-intensity shutdowns
    are failures too (F5). Lab 04/08 must prove where to hook so Elixir's
    `sasl: false` primary filter does not eat them (a handler-level filter
    cannot see a stopped event).
13. Client-side, line-shift-proof fingerprint (F7); count every
    occurrence; never "drop as duplicate" without incrementing a counter
    (F6).
14. Automatic, cheap breadcrumbs: Logger lines below error, telemetry
    spans (Plug/Phoenix/Bandit, Ecto queries with timings, Req/Finch,
    Oban), in a per-process or per-request ring with µs timestamps;
    attached to the failure record (F8). Costs from lab 06.
15. The handler does the minimum in the caller (copy bounded term, enqueue
    into a bounded buffer, return); heavy work in our own process; under
    overload drop and count, **never** block the app (F10, F11).
16. Storage in the app's Postgres, so Sentry-down and network retries do
    not exist on the error path (F12); optional forwarder to
    Sentry-compatible endpoints later.
17. `Plug.Exception.status/1` decides "expected" (4xx) for every source;
    expected ones are counted, not raised as issues (F14).
18. A small `Blackbox.report/2` and an opt-in monitor for key processes for
    the failures that leave no log (init crash under `start`, bare spawn
    exits, `{:error, _}` returns) (F13).
19. Store terms with size caps rather than JSON so exotic metadata never
    kills an event (F17).
20. Add what Sentry never records: pid, registered name, label,
    ancestors/supervisor, node health snapshot (run queue, memory,
    process count) at the moment of the failure, release/git sha.

## Sources

sentry-elixir (github.com/getsentry/sentry-elixir), clone in
`scratchpad/src/sentry-elixir`; tag `13.5.1` = `ac8f14e` (2026-09-02),
main = `edb3ecf` (2026-09-24). Files read (main unless noted):
`lib/sentry/application.ex`, `lib/sentry/logger_handler.ex`,
`lib/sentry/logger_handler/error_backend.ex`,
`lib/sentry/logger_handler/rate_limiter.ex`, `lib/sentry/logger_utils.ex`,
`lib/sentry/plug_capture.ex`, `lib/sentry/plug_context.ex`,
`lib/sentry/live_view_hook.ex`, `lib/sentry/context.ex`,
`lib/sentry/event.ex`, `lib/sentry/client.ex`, `lib/sentry/dedupe.ex`,
`lib/sentry/default_event_filter.ex`, `lib/sentry/sources.ex`,
`lib/sentry/options.ex`, `lib/sentry/config.ex` (and `@13.5.1`),
`lib/sentry/transport.ex`, `lib/sentry/transport/sender.ex`,
`lib/sentry/transport/sender_pool.ex`, `lib/sentry/telemetry_processor.ex`,
`lib/sentry/telemetry/buffer.ex`, `lib/sentry/integrations/telemetry.ex`,
`lib/sentry/integrations/oban/error_reporter.ex`, `lib/sentry/test.ex`,
`lib/mix/tasks/sentry.install.ex`, `pages/setup-with-plug-and-phoenix.md`,
`pages/upgrade-14.x.md`, `CHANGELOG.md`. Commits: `c4b2fac` (#739),
`d571a6c` (#900), `752f218` (#1073), `62d56a0` (#1099), `676e43c` (#1102),
`13c0301` (#1208), `70481f5`..`519c2b4` (#1220-#1224).

Bandit 1.12.5 (1charta `deps/bandit`): `lib/bandit/logger.ex:47-60`,
`lib/bandit/pipeline.ex:222-239`.
Elixir 1.20.4: `lib/logger/lib/logger/utils.ex:12-13` (SASL stop).

GitHub issues (api.github.com search, 457 issues, 2026-09-27): #79, #93,
#101, #137, #271, #337, #349, #353, #360, #374, #445, #446, #484, #485,
#486, #520, #527, #535, #542, #667, #736, #827, #837, #895, #932, #933,
#936, #1040, #1045, #1047, #1179, #1219. Raw dump:
`scratchpad/gh01/all.json`.

Lab: `docs/research/0031-errors/lab/01-sentry/` (tests `test/*_test.exs`),
log `docs/research/0031-errors/logs/01-sentry.log`. All lab claims are
**verified**; all source claims are **read**.
