# 02 The BEAM error/observability field, source-read

Agent 02 for ADR 0031. Started 2026-09-27. Status: done 2026-09-27. Source-read only, no lab (every claim is **read** unless marked).

## Summary for the lead

1. No existing BEAM tool catches everything. ErrorTracker, the only self-hosted one, has **no `:logger` handler** (Phoenix/LiveView/Oban telemetry + a Plug wrapper only), so GenServer, Task, spawn and Hologram crashes never reach it.
2. The field agrees that a `:logger` handler (or New Relic's primary filter) is the one universal hook; telemetry only adds context. Tower moved Bandit capture from telemetry to its logger handler (PR #86).
3. Tower, AppSignal and Honeybadger only work because Elixir's translator adds `crash_reason`. Honeybadger regex-parses the formatted text and needed a second parser for Elixir 1.19. Rollbax matches OTP format strings by arg count, so it probably misses GenServer crashes during a `call` (read, not run). New Relic is the only one that matches the structured OTP report.
4. OTP reports already hold data nobody uses: `last_message`, state (after `format_status/1` redaction), the `sys` log, `client_info` (the caller's pid and stack), `process_label`, received messages, the whole process dictionary (`$callers`, breadcrumbs) and linked neighbours (`gen_server.erl:2764-2815`, `proc_lib.erl:963-1090`).
5. Safety gaps across the field: OTP silently removes a handler that raises, and telemetry silently detaches a handler that raises. Nobody re-attaches. ErrorTracker writes to the DB inside the crashing process. Honeybadger and Rollbax send to one GenServer with no mailbox limit, and Bugsnag starts one Task per error. Only Scout (queue of 500), New Relic (20 per minute) and OTel logs (2048) set bounds.
6. For breadcrumbs, a private process-dictionary ring (Honeybadger: 40 entries; Sentry keeps 100 in logger metadata) beats logger metadata, which leaked into log lines (Honeybadger #475/#487). Honeybadger's gen_event backend, though, reads the logger process's dictionary, so crashes caught through the logger lose their breadcrumbs (read). Fix: read the dictionary in-process, or take it from the crash report.
7. Linking a crash to its request: New Relic traces spawns with the legacy global tracer, which `recon_trace:clear/0` wipes node-wide. OTel instead reads the parent's dictionary through `$callers`/`$ancestors`. Use the OTel way first; OTP 27+ trace sessions can come later.
8. Handling one failure seen twice: New Relic puts a marker in the process dictionary when it reports, then finds it again in the crash report's `dictionary`. Copy that, plus ignoring errors with `plug_status < 500`.
9. Current fingerprints break easily: ErrorTracker hashes kind + `file:line` + function, and Tower hashes the message plus the full stack with line numbers. Better: kind + exception module + in-app `{m, f, a}`, with no lines.
10. What to copy: ErrorTracker's issue/occurrence upsert, reopen-on-recurrence, mute, pruner and versioned migrations; Tower's reporter behaviour and its `ReportEventError` loop guard; observer_cli 2.0's versioned JSON schema for AI agents. Also watch for application exits: OTP logs them at `:notice`, below `:error`.

## Method

Shallow clones (`git clone --depth 1`) into the session scratchpad `src/`, commit hashes recorded per repo.
Everything below is **read** (source) unless marked **verified**.

## Per tool

Source commits (all cloned 2026-09-27, `--depth 1`, list in `logs/02-clones.log`):
error-tracker 630ea49 (v0.9.0), tower 057aa00, appsignal-elixir 4aef537, honeybadger-elixir 1eaf148,
rollbax 5ea0ab4 (last commit 2021-05-13), bugsnag-elixir 0e1e2ba (2022-07-30), elixir_agent e2a0e33,
scout_apm_elixir d7ae4a5, opentelemetry-erlang 9cb8b36, opentelemetry-erlang-contrib 0cbae53,
spandex a40c10a (2022-10-20), prom_ex 2ebcd0e, phoenix_live_dashboard 83a0bd1, recon cb45e7b,
observer_cli 04aee9f, erlang/otp de741b7 (main, OTP_VERSION 30.0-rc0; logger/proc_lib code paths
cited are unchanged in shape since OTP 21, and 1charta runs OTP 28). Paths below are relative to each repo root.

### 1. ErrorTracker (elixir-error-tracker/error-tracker, v0.9.0)

The closest thing to what 1charta wants to build: self-hosted, Ecto-backed (Postgres, MySQL, SQLite),
LiveView dashboard mounted in the host router.

**Capture hooks (read).**
- `lib/error_tracker/application.ex:14-17` attaches exactly two telemetry integrations at boot: Oban and Phoenix.
- `lib/error_tracker/integrations/phoenix.ex:52-65`: `[:phoenix, :router_dispatch, :start|:exception]`,
  LiveView `mount/handle_params/handle_event/render :exception`, LiveComponent `update/handle_event :exception`.
  The moduledoc (`:19-24`) admits it misses anything that raises in an Endpoint plug before the router.
- `lib/error_tracker/integrations/plug.ex:60-93`: a `use ErrorTracker.Integrations.Plug` macro that wraps
  `call/2` via `defoverridable` + `rescue`/`catch` (Plug.ErrorHandler style), reraises. Dedupe with the Phoenix
  telemetry path via a process-dictionary flag `:error_tracker_router_exception_reported` (`plug.ex:96-100`).
- `lib/error_tracker/integrations/oban.ex:48-84`: `[:oban, :job, :start]` sets context, `[:oban, :job, :exception]`
  reports. `{:error, _}` returns get a fake one-frame stacktrace `Worker.perform/2` (`:78-81`), so all such errors
  of one worker collapse into one issue (documented at `:15-27`).
- Manual: `ErrorTracker.report/3` (`lib/error_tracker.ex:133`).
- **No `:logger` handler at all** (`grep -rn "logger\|add_handler" lib` returns nothing). So a crash in a
  GenServer, Task, `spawn`, supervisor child, or any `Logger.error` is invisible. For 1charta (Hologram, not
  LiveView) that means: only the Plug wrapper would fire; Hologram action/command crashes, sidecar processes,
  PubSub handlers: all missed.

**"Before" data.** Per-process context map in `Process.put(:error_tracker_context, ...)` (`error_tracker.ex:235-241`),
and breadcrumbs as a plain list of **strings** in `:error_tracker_breadcrumbs` (`:268-275`), appended with
`++` (O(n)) and **unbounded** (doc at `:257-265` just warns). Automatic breadcrumbs only from Ash/Splode
exceptions' `bread_crumbs` field (`:321-327`). No timestamps, no categories, no level. Context from the
request (`plug.ex:112-124`: host, path, query, method, headers minus cookies, params, ip) and LiveView
(view, uri, params, last event + params). Nothing about process state, message, system health.

**Event model / grouping.** `Error` = kind, reason, source_line, source_function, status, muted
(`schemas/error.ex:26-38`). Fingerprint = `sha256(kind <> "file:line" <> "Mod.fun/arity")` of the first
stack frame that belongs to `:otp_app` (`error.ex:43-66`, `stacktrace.ex:57-61`). The reason is excluded
(good) but the **line number is in**, so any edit above the crash site opens a new issue. Stacktrace
stored as embedded JSON lines, no source context, no args.

**Storage / transport.** Synchronous in the caller: `report/3` runs `Repo.one` + `Repo.transaction`
with two `insert!` in the crashing process (`error_tracker.ex:329-369`). So (a) DB latency is added to the
failing request/LiveView, (b) if the DB is down the `insert!` raises inside a telemetry handler, which makes
`:telemetry` **detach the handler permanently** (telemetry's documented behaviour on a raising handler) and all
further Phoenix/Oban capture stops silently, (c) a flood = one transaction per error, no rate limit, no dedupe
window. Upsert on `fingerprint` flips `status` back to unresolved (`:346-354`). Pruner plugin deletes
resolved errors older than 24 h, 200 per run, every 30 min (`plugins/pruner.ex:11-29`); unresolved ones grow forever.

**UI.** LiveView dashboard (`web/live/dashboard.ex`, `show.ex`), router macro `error_tracker_dashboard/2`,
search, resolve/unresolve, mute (mute = keep storing, stop telemetry notifications, `error_tracker.ex:179-195`).
Occurrence navigator of 50 (`show.ex:12`). Emits its own telemetry `[:error_tracker, :error, :new|:resolved|:unresolved]`,
`[:error_tracker, :occurrence, :new]` for notifications (`telemetry.ex`).

**Misses.** Everything outside Phoenix/Oban/manual; line-shift-fragile grouping; unbounded string
breadcrumbs; sync DB write in the hot path; no scrubbing beyond a user `filter` module and dropping cookies;
no sampling/rate limiting; depends on LiveView for the UI (1charta has none).

**Copy:** the schema split errors/occurrences with upsert on fingerprint, the resolve-reopens-on-recurrence
rule, mute, the installer + versioned migrations (`migration/postgres/v01..v05`), telemetry events for
notifications. **Do better:** logger handler, async bounded writer, stable fingerprint, structured breadcrumbs.

### 2. Tower (mimiquate/tower, 057aa00)

Reporter-agnostic capture layer: it catches, normalizes to `%Tower.Event{}`, and fans out to "reporters"
(separate packages: tower_sentry, tower_error_tracker, tower_rollbar, tower_honeybadger, tower_bugsnag,
tower_email, tower_slack; `lib/tower.ex:1-30`). It is the best existing answer to "catch everything", and
it is small (1294 lines).

**Capture hooks (read).**
- One `:logger` handler, id `Tower`, `level: :all` (`lib/tower/logger_handler.ex:10-30`), with two domain
  filters: stop its own logs (`[:elixir, :tower, :logger_handler]`) and stop `[:elixir, :oban]` to avoid
  double reports with the Oban hook.
- Pattern-matches on `meta.crash_reason` (`logger_handler.ex:53-103`): `{exception, stack}` = exception,
  `{{:nocatch, r}, stack}` = throw, `{reason, stack}` = exit, bare `crash_reason` = exit with empty stack
  (old Plug.Cowboy). A special clause unwraps Bandit < 1.6.2's `Plug.Conn.WrapperError` map and pulls the
  `conn` out of it (`:53-76`). So process crashes (proc_lib crash reports, GenServer terminate reports,
  Task reports, Bandit/Cowboy request crashes) arrive **only because Elixir's Logger translator adds
  `crash_reason` to their metadata**; Tower never parses the raw OTP report itself.
- Every other log event (`Logger.error("...")`, supervisor reports without crash_reason) becomes a
  `:message` event if `level >= config :tower, :log_level` (`:105-108`, `:125-127`). Formats
  `{:report, _}` via the event's `report_cb` (`:151-167`) and `{fmt, args}` with the logger `truncate`
  limit (`:179-191`). Unknown shapes are reported as "Unrecognized log event" (`:111-123`).
- `[:oban, :job, :exception]` telemetry (`lib/tower/oban_exception_handler.ex:8-39`), keeps job id,
  worker, attempt, max_attempts.
- No Plug wrapper, no Phoenix telemetry: HTTP errors are captured through the web server's crash log
  (Bandit/Cowboy log the request process crash with `crash_reason` and `conn` in metadata).
- Manual `Tower.report/3,4`, `report_exception`, `report_throw`, `report_exit`, `report_message`
  (`tower.ex:381-520`).

**"Before" data.** None of its own. Picks configured keys from the log event metadata merged with
`Logger.metadata()` of the handling process (`event.ex:179-183`, config `:logger_metadata`, e.g.
`[:request_id, :user_id]`, `tower.ex:243-270`). Passes the whole `log_event` and the `plug_conn` to reporters.

**Event model / grouping.** `Tower.Event` = id (UUIDv7), similarity_id, datetime, level, kind
(`:error|:exit|:throw|:message`), reason, stacktrace, log_event, plug_conn, metadata, by (`event.ex:7-45`).
`similarity_id = :erlang.phash2([level, kind, normalized_reason, stacktrace])` (`event.ex:220-233`), where
normalization only replaces `#PID<...>` and `\d+ms` in the message (`:236-248`). The **full stacktrace with
line numbers and the message** are in the hash, so it groups much less than Sentry or ErrorTracker.

**Storage / transport.** Tower stores nothing (except `Tower.EphemeralReporter`, an Agent keeping the last 50
events for tests, `ephemeral_reporter.ex:2-65`). `report_event` calls each reporter **synchronously in the
calling process** (for the logger handler that is the process that logged, i.e. the crashing process or
the proc_lib crasher) inside `:telemetry.span([:tower, :report_event])` (`tower.ex:560-580`). A reporter
exception is re-raised in a separate Task under `Tower.TaskSupervisor` as `ReportEventError`, and a
`ReportEventError` from reporter X is never sent back to X (`:555-558`): a neat anti-recursion trick.
No rate limit, no dedupe window, no buffer: each reporter must be async itself.

**Misses.** No "before" at all; nothing for crashes whose report lacks `crash_reason` (they degrade to
a message string); fingerprint unstable; no request/Phoenix context beyond the conn in Bandit's metadata;
no storage/UI. **Copy:** the handler shape (one handler, `level: :all`, domain filter against its own
logs), dispatch on `crash_reason`, the "Unrecognized log event" catch-all, the reporter behaviour so the
lib can later forward to Sentry-compatible endpoints, the ReportEventError loop guard.

### 3. AppSignal (appsignal/appsignal-elixir 2.17.5, 4aef537)

APM first, errors are an attribute of a span. Data goes through a **NIF** (`lib/appsignal/nif.ex`, 402 lines)
into a bundled native agent process that batches and ships to AppSignal's SaaS.

**Capture hooks (read).**
- Still a **legacy Logger backend** (`:gen_event`), not an OTP `:logger` handler:
  `lib/appsignal/error/backend.ex:11-25`, added via `LoggerBackends.add/2` on Elixir 1.15+
  (`lib/appsignal/utils/logger_handler.ex`). It only looks at `:error` events whose metadata has
  `crash_reason: {reason, stack}` (`backend.ex:27-51`), i.e. the same Elixir-translator dependency as Tower.
  Skips anything with `:cowboy` in the domain (`:42`) because the Phoenix integration reports those.
- The trick worth copying: on a crash it finds the **crashing pid's open span** in an ETS
  `duplicate_bag` keyed by pid (`lib/appsignal/tracer.ex:13`, `lookup/1` at `:74`), using
  `conn.owner` for Plug crashes (`backend.ex:53-55`), and attaches the error to the innermost span
  (`:70-74`). If the pid has no span it creates a `"background_job"` span just for the error (`:64-68`).
  So a GenServer crash lands inside the trace that was running in that process.
- Telemetry attach for Ecto (`ecto.ex:43`), Oban (`oban.ex:31`), Finch (`finch.ex:17`),
  Tesla, Absinthe; Phoenix/LiveView/Plug live in the separate `appsignal_phoenix`/`appsignal_plug` packages.
- `Appsignal.Monitor` (`monitor.ex:21-35`) monitors every pid that opened a span, deletes its ETS spans on
  `:DOWN` (leak protection, and a periodic `:sync`). No error capture from `:DOWN` itself.
- A separate `:logger` handler `:appsignal_log` (`logger/handler.ex:24-35`) ships log lines (not errors).

**"Before" data.** The span tree of that process (Ecto queries, HTTP calls, custom `instrument`
blocks with timings) is the breadcrumb trail; sample data (params, session, environment) per span.
Minutely **Erlang probe** (`probes/erlang_probe.ex:32-116`): io, schedulers, process count/limit,
`:erlang.memory()`, atoms, run queue lengths, scheduler wall time. These are time series, not attached
to the error event itself.

**Grouping / storage / UI.** Server side (SaaS), keyed by exception name + action/namespace (not in the
client). Config: `ignore_errors`, `ignore_namespaces`, `filter_parameters`, `send_params`
(`config.ex:21-40`). **Misses:** crashes without `crash_reason`; `Logger.error` messages are logs not
errors; a crash in a process that never opened a span has no context at all; no process state/last message.

### 4. Honeybadger (honeybadger-io/honeybadger-elixir 0.30.1, 1eaf148)

Error tracker SaaS plus "Insights" (structured events). The most complete breadcrumb story among the
Elixir clients, and the clearest example of what goes wrong when the logger path parses **formatted text**.

**Capture hooks (read).**
- Legacy Logger backend `Honeybadger.Logger` (`:gen_event`), added with `Logger.add_backend` when
  `use_logger` (`lib/honeybadger.ex:203-205`). Handles `:error` events only (`lib/honeybadger/logger.ex:27-49`):
  `crash_reason: {reason, stack}` = exception; atom crash_reason = exit; anything else becomes
  `%RuntimeError{message: message}` unless `sasl_logging_only` (`:34-45`). So by default **every
  `Logger.error` string is an error notice**. Skips `ignored_domains` and its own `:honeybadger` app (`:28-29`, `:79-86`).
- **GenServer last message and state are regex-scraped from the translated text**: `extract_details/1`
  (`logger.ex:96-186`) has one clause set for Elixir 1.17/1.18 chardata shapes (`:96-112`) and a second,
  regex-based set because "Elixir >= 1.19 flattens chardata to a charlist before reaching backends"
  (`:114-186`, e.g. `~r/Last message(?: \(from [^)]+\))?: (.+)\nState: /s` at `:134`). The state arrives
  as an inspected, already-truncated string. Evidence that the text path breaks on every Elixir minor;
  the raw OTP report (`#{label => {gen_server,terminate}, last_message => ..., state => ...}`) is stable.
- `Honeybadger.Plug` = `use Plug.ErrorHandler` (`lib/honeybadger/plug.ex:45-70`), ignores
  `FunctionClauseError` from `do_match` (router 404s, `:57`).
- Insights (`lib/honeybadger/insights/*.ex`): telemetry for Plug, Ecto, LiveView, Oban, Finch, Tesla,
  Absinthe, Ash, via a `Base` macro (`insights/base.ex:93`). These produce events (APM-ish), not error notices.

**"Before" data: breadcrumbs.**
- Per-process **ring buffer of 40** in the process dictionary (`breadcrumbs/collector.ex`: `@buffer_size 40`,
  key `:hb_breadcrumbs`); metadata sanitized to depth 1 on insert. The ring is a list with `rest ++ [item]`
  (`breadcrumbs/ring_buffer.ex`), O(n) per add, fine at n=40.
- Automatic breadcrumbs via telemetry (`breadcrumbs/telemetry.ex`): `[:phoenix, :router_dispatch, :start]`
  (route, plug, pipe_through) and every configured Ecto repo's `[..., :query]` (query text, source, timings).
  That is all: no HTTP client calls, no Logger lines, no PubSub, no messages.
- The docs admit the model's limit (`lib/honeybadger.ex:140-145`): breadcrumbs live in the calling
  process; "if you are sending messages between processes, breadcrumbs will not transfer automatically".
- **Consequence found by reading:** `Honeybadger.Logger.notify/3` calls `Collector.breadcrumbs()`
  (`logger.ex:73`), which reads the process dictionary of **the process running the logger backend**
  (the Logger/LoggerBackends gen_event process), not of the crashed process. So breadcrumbs on
  crashes captured through the logger (GenServer, Task, spawn) are just the one "error" crumb; only the
  Plug path (which runs in the request process) carries the request's real trail. (Read, not run; agent
  06/08 can prove the general fact: a logger handler runs in the logging process, a gen_event backend does not.)

**Grouping / storage / transport.** Server side, overridable client-side by a `FingerprintAdapter`
behaviour (`fingerprint_adapter.ex`). One `Honeybadger.Client` GenServer; `send_notice/1` is a
`GenServer.cast` (`client.ex:68-72`) and the HTTP post runs inside `handle_cast` (`:151-170`):
**unbounded mailbox, no drop, no rate limit** on the notice path (the events path has a rate-limit warning, `:268`).

**Misses.** Breadcrumbs lost for non-request crashes; text scraping; flood = mailbox growth in one process;
no process/system snapshot. **Copy:** ring buffer of ~40 typed crumbs `{category, message, metadata, timestamp}`,
Ecto + router telemetry as default crumb sources, `sasl_logging_only`-style switch for plain `Logger.error`.

### 5. Rollbax (ForzaElixir/rollbax 0.11.0, last commit 2021-05-13) and Bugsnag (bugsnag-elixir 3.0.2, last commit 2022-07-30)

Both are effectively unmaintained and both capture through the **pre-OTP-21 `:error_logger` API**, which
OTP keeps as a compatibility layer (an `error_logger` handler inside `:logger` that converts events carrying
`error_logger => #{tag => ...}` metadata back to `{Format, Args}` via the report's `format_log/1` callback;
see gen_server.erl:2818-2823 comment: "kept for backwards compatibility with legacy error_logger event handlers").

- **Rollbax**: `:error_logger.add_report_handler(Rollbax.Logger)` when `enable_crash_reports`
  (`lib/rollbax.ex:86-89`); a chain of `Rollbax.Reporter` modules (`lib/rollbax/logger.ex:52-110`).
  `Rollbax.Reporter.Standard` pattern-matches the **format string and exact arg count**:
  `'** Generic server ' ++ _, [name, last_message, state, reason]` (`lib/rollbax/reporter/standard.ex`,
  "Errors in a GenServer"). Modern OTP appends the process label, the `sys` debug log and the
  **client info** (caller pid + stacktrace) to the args (`otp gen_server.erl:2933-2981`), so a GenServer that
  crashes while serving a `call` (client_info set) produces more than four args and falls through the
  match. **Read, not run:** Rollbax likely misses exactly the common case. Transport: one GenServer, cast,
  hackney pool of 20, a `rate_limited?` flag from Rollbar's 429 (`lib/rollbax/client.ex:53-88`).
  Good idea kept: last message and state as structured `custom` fields.
- **Bugsnag**: `:error_logger.add_report_handler(Bugsnag.Logger)` (`lib/bugsnag.ex:9`); handles only
  `{:error_report, _, {_, _, [message | _]}}` and reads `message[:error_info]` (`lib/bugsnag/logger.ex`),
  i.e. only proc_lib **crash reports** (the `error_info` key of `proc_lib:my_info_1`, see below). Every
  report is sent from a `Task.Supervisor` child (`lib/bugsnag/reporter.ex:17-18`): one process per error,
  unbounded under a flood. Uses the deprecated `Logger.warn`.

Lesson for the lib: match on the **structured report map** (`label`, keys), never on format strings or arg
counts; those change with every OTP/Elixir release (compare Honeybadger's two parser generations).

### 6. OTP's own crash reports and logger internals (erlang/otp de741b7, main; same shape in OTP 28)

This is the ground truth every tool above consumes, second hand. Everything here is **read**; agent 04 verifies
what actually arrives in a handler.

**Where reports are emitted (and in which process).**
| Emitter | file:line | label | level | domain | runs in |
|---|---|---|---|---|---|
| proc_lib crash (any `proc_lib`/`spawn_link` via OTP behaviours, Elixir Task/GenServer/Agent) | `stdlib/src/proc_lib.erl:951-961` | `{proc_lib,crash}` | error | `[otp,sasl]` | the crashing process |
| gen_server terminate | `stdlib/src/gen_server.erl:2774-2799` | `{gen_server,terminate}` | error | `[otp]` | the server process |
| gen_statem terminate | `gen_statem.erl:4983` | `{gen_statem,terminate}` | error | `[otp]` | the server |
| gen_event handler crash | `gen_event.erl:2124` | `{gen_event,terminate}` | error | `[otp]` | the manager |
| supervisor child_terminated / start_error / shutdown (max intensity) / shutdown_error | `supervisor.erl:320-331`, `:1018-1598` | `{supervisor,Error}` | error | `[otp,sasl]` | the supervisor |
| application exit | `kernel/src/application_controller.erl:2166-2176` | `{application_controller,exit}` | **notice** | `[otp]` | application_controller |
| plain `spawn` crash ("Error in process ... with exit value") | emulator, sent to the `system_logger` process | none (format string) | error | `[otp]`? (agent 04) | `logger_proxy` (`kernel/src/logger_proxy.erl:130-140`) |

- `crash_report/4` skips `normal`, `shutdown`, `{shutdown,_}` (`proc_lib.erl:951-953`); so does
  gen_server (`gen_server.erl:2740-2744`). A tracker that wants "abnormal shutdown loops" must look elsewhere
  (supervisor reports).
- **An application stop is logged at `:notice`** (`application_controller.erl:2167`). A handler at
  `level: :error` never sees "Application my_app exited: shutdown", the one event that says the node is
  going down. The lib's handler must run at `:all`/`:notice` and route by label, not by level alone.
- Plain-`spawn` crashes come from the emulator via `erlang:system_flag(system_logger, Pid)`, handled in
  `logger_proxy`; when the proxy enters drop mode it sets `system_logger` to `undefined`
  (`logger_proxy.erl:147,153-157`), i.e. **emulator errors are silently discarded under overload**.

**What the proc_lib crash report carries** (`proc_lib.erl:963-988`): `initial_call`, `pid`,
`registered_name`, `process_label` (OTP 27+ `proc_lib:set_label/1`, `:868-871`), `error_info = {Class, Reason,
Stacktrace}`, `ancestors`, `message_queue_len`, **`messages`** (up to `error_logger_format_depth` messages
actually *received* out of the mailbox, `:998-1023`), `links`, **`dictionary`** (the whole process
dictionary minus `$ancestors`/`$initial_call`/`$process_label`, `:1025-1036`; so Elixir's `$callers`,
`:"$logger_metadata$"` and any breadcrumb ring kept in the pdict are in the report), `trap_exit`, `status`,
`heap_size`, `stack_size`, `reductions`, plus a **neighbour report** for each linked process
(`linked_info/1`, `:1056-1090`: pid, initial call, current function, mailbox length, links, heap, no messages
or dictionary). Nobody in the field uses the neighbour or dictionary data; Tower/AppSignal/Honeybadger only
read `crash_reason` added by the Elixir translator.

**What the gen_server terminate report carries** (`gen_server.erl:2764-2799`): `name`, `last_message`,
`state`, `log` (the `sys` debug log if the server runs with `debug: [log: N]`), `reason = {Reason, ST}`,
**`client_info`** = the caller's pid and its **current stacktrace** if the crash happened inside a
`call` from a local, live process (`client_stacktrace/1`, `:2801-2815`), `process_label`. State and message
first pass through the module's `format_status/1` callback (`:2764-2771`): that is the standard OTP hook
for **scrubbing secrets from state** and the lib should honour it rather than invent its own.

**Size limits.** `error_logger_format_depth` (kernel env; default unlimited) bounds message queue and dictionary
via `error_logger:limit_term` (`proc_lib.erl:996-1003`, `:1025-1027`); formatters apply `depth`/`chars_limit`
later. The raw report a handler receives can be **huge** (full state, whole dictionary): the lib must bound
it itself (`:erts_debug.flat_size`-based truncation) before storing.

**How handlers are called** (`kernel/src/logger_backend.erl:33-86`): the primary filters, then for each
handler its filters, then `Module:log(Log, Config)` **in the logging process**, inside `try ... catch`;
a crash **removes the handler** (`logger:remove_handler(Id)`) and logs `removed_failing_handler`
(`:54-67`). A crashing filter is removed too (`:122-136`). So a buggy handler silently switches error
capture off forever: the lib needs a watchdog (`logger_handler_watcher.erl` exists for this pattern in OTP)
(OTP has no re-adder: `logger_handler_watcher.erl` does the inverse, it removes a handler when the handler's own process dies) or a supervised re-adder, and must `try/catch` everything inside `log/2`.

**Overload protection** (`logger_olp.hrl:36-66`) applies only to handlers built on `logger_olp`
(`logger_std_h`, `logger_disk_log_h`, `logger_proxy`): sync mode at 10 queued, drop at 200, flush at 1000,
burst limit 500 events per 1000 ms, optional kill at 20000 / 3 MB. A custom handler gets none of it by default;
it can reuse `logger_olp` (undocumented/internal) or roll its own counters (agent 08).

**Process metadata** lives in the process dictionary under `?LOGGER_META_KEY` (`logger.erl:1346-1362`);
Elixir's `Logger.metadata/1` writes the same key. That is why metadata reaches the handler for free (the
handler runs in the logging process) and why it is lost when the report is produced elsewhere (emulator,
supervisor reporting on a dead child).

### 7. New Relic elixir_agent (newrelic/elixir_agent 1.42.0, e2a0e33)

The most BEAM-native design in the field, and the only one that uses tracing to follow work across processes.

**Capture hooks (read).**
- A **`:logger` primary filter**, not a handler (`lib/new_relic/error/logger_filter.ex:4-13`): it runs for
  every log event in the logging process, reports as a side effect and always returns `:ignore` so it never
  changes logging. Matches `meta.error_logger.type == :crash_report` with `{:report, %{report: [report | _]}}`
  (proc_lib crash reports, `:15-29`) and `error_logger.tag == :error_msg` reports with a `reason`
  (gen_server/gen_statem terminate etc., `:43-57`). Since it keys on the **structured OTP report**
  (the `error_logger` metadata that OTP attaches, see section 6), it is independent of Elixir's translator.
  Cost: a pattern match on every log event that passes the primary level. Risk: a crash in a primary filter
  removes the filter (`logger_backend.erl:122-136`) exactly like a handler.
- Telemetry for Plug, Phoenix, LiveView, Ecto, Oban, Finch, Redix, Absinthe (`lib/new_relic/telemetry/*.ex`).
- `NewRelic.SignalHandler` inserts itself before `:erl_signal_handler` in `:erl_signal_server` to react to
  SIGTERM (`lib/new_relic/signal_handler.ex:9-31`); not error capture, but the only tool that hooks OS signals.

**Following work across processes (the "request chain").** `NewRelic.Transaction.ErlangTrace`
(`lib/new_relic/transaction/erlang_trace.ex`): every transaction process calls
`:erlang.trace(self(), true, [:call, :set_on_spawn, :timestamp, tracer: tracer])` (`:78-82`), with global
`trace_pattern` + `return_trace` on `proc_lib:spawn_link/start_link` and `Task.Supervised.spawn_link/start_link`
(`:86-110`). Each `return_from` message = "this transaction spawned that pid" (`track_spawn`, `:40-60`).
A crash in a tracked child is then reported **into the parent's transaction** (`Transaction.Sidecar.tracking?()`
switch in the filter). Overload protection: if the tracer's mailbox reaches 500 it exits and tracing is
re-enabled after 60 s (`:13-14`, `:112-124`). Caveat: this is the legacy single global tracer per traced
process; it collides with `recon_trace`, `:dbg`, observer_cli or another APM tracing the same process. OTP 27+
**trace sessions** (`:trace.session_create/3`) remove that collision (agent 06 measures them). Elixir's
`$callers` gives the same parent link for Tasks without any tracing, but not for `proc_lib:spawn_link`
children started by libraries.

**Dedupe manual vs crash report via the process dictionary.** `NewRelic.Transaction.Reporter` puts
`{kind, reason, first_frame}` under `:nr_error_explicitly_reported` in the pdict (`transaction/reporter.ex:105`),
and the crash-report path compares it with `report[:dictionary][:nr_error_explicitly_reported]`
(`error/reporter/crash_report.ex:45`). This works only because the proc_lib crash report carries the dead
process's dictionary. Copy this: it is the cleanest dedupe for "reported by Plug/telemetry, then crashed".
Also: ignores crash reports whose reason carries `plug_status < 500` (`crash_report.ex:6-14`) and Plug.Cowboy's
re-raise (`:16-24`).

**"Before" data.** The transaction trace (segments from telemetry), attributes, and minutely samplers:
`Sampler.Beam` (reductions, run queue, memory by kind, GC, IO, scheduler utilization; `sampler/beam.ex:15-68`)
and `Sampler.TopProcess` (top 5 processes by memory and by mailbox, with reductions delta;
`sampler/top_process.ex:47-77`). Not attached to the individual error.

**Storage / transport.** Harvest cycle per minute; error traces use a **reservoir of 20 per cycle**, beyond
that only counted (`harvest/collector/error_trace/harvester.ex:64-72`). That is New Relic's flood defence.

### 8. Scout APM (scoutapp/scout_apm_elixir 2.1.0, d7ae4a5)

APM with a newer error module. **Capture:** telemetry only: `[:phoenix, :router_dispatch, :exception]` and
`[:phoenix, :error_rendered]` (`lib/scout_apm/instruments/phoenix_error_telemetry.ex:21-35`), LiveView
exception events (`live_view_telemetry.ex:154,220,276`), Oban (`oban_telemetry.ex:107`), and exceptions inside
its own `instrument` blocks (`tracing.ex:109`). Its `:logger` handler (`logging/log_handler.ex:50`) ships logs, it
does not create errors. So GenServer/Task/spawn crashes are invisible unless they happen inside a traced
request. **Transport:** `ErrorService` GenServer with a bounded `:queue`: batch 5, **max queue 500**
(drop beyond), flush every 1 s (`error/error_service.ex:3-15`). The one small, explicit memory bound in the
field worth copying as a default.

### 9. Spandex (spandex-project/spandex, last commit 2022-10-20) and Datadog

Tracing-only (Datadog APM via `spandex_datadog`); unmaintained, superseded by OpenTelemetry + Datadog's OTLP
intake. Errors are recorded manually or by its Phoenix/Ecto integrations with `span_error/3`
(`lib/spandex.ex:243-245`, `lib/tracer.ex:199`), which marks the current span `error: true` with type,
message, stack. Trace state lives in the **process dictionary** (`lib/strategy/pdict.ex:11-27`), so a
crash in another process has no trace unless the user propagates it. No logger capture. Relevant only as
evidence that "error = attribute of a span" does not catch process crashes.

### 10. OpenTelemetry Erlang/Elixir (opentelemetry-erlang 9cb8b36, contrib 0cbae53)

**Exception recording.** `otel_span:record_exception/5,6` (`apps/opentelemetry_api/src/otel_span.erl:204-236`)
adds a span **event named `exception`** with `exception.type` = `"Class:Term"` formatted with depth 10 and
1024 chars, `exception.stacktrace` as one formatted string, optional `exception.message`. No fingerprint,
no structured frames, no grouping: it is transport, not tracking. Contrib instrumentations call it from
telemetry: Phoenix (`opentelemetry_phoenix.ex:322,406`), Bandit `[:bandit, :request, :exception]`
(`opentelemetry_bandit.ex:183-205,496-516`, sets `error.type` and status from `Plug.Exception.status/1`),
Oban (`opentelemetry_oban.ex:135`, `plugin_handler.ex:66-89`), Ecto, Finch, Req, Tesla, Cowboy, Broadway,
Commanded, Absinthe... (`instrumentation/`, 23 packages).

**Context propagation (the "request chain").** Context is in the process dictionary. The
`opentelemetry_process_propagator` package recovers the parent context by reading the **parent's
dictionary** through `process_info(Pid, dictionary)` for the first pid in `$callers` (Elixir Tasks) or
`$ancestors` (proc_lib) (`propagators/opentelemetry_process_propagator/src/opentelemetry_process_propagator.erl:10-49`,
`lib/opentelemetry_process_propagator.ex:53,93-111`). The same move gives a crashed Task the request's
trace id and breadcrumbs, cheaply and without tracing, as long as the parent is still alive.

**Logs.** `otel_log_handler` (experimental app, `apps/opentelemetry_experimental/src/otel_log_handler.erl`) is a
`:logger` handler that batches log events per instrumentation scope in a `gen_statem` with
`max_queue_size` default 2048 (`:50`, `:144-160`, `:212-213`) and exports OTLP. It does not turn crash
reports into exceptions on spans.

**Misses as an error tracker.** No capture of crashes outside spans, no grouping, no UI (it needs a backend:
Jaeger, Tempo, Honeycomb, SigNoz, Sentry's OTLP intake...). **Take:** emit/accept `trace_id`/`span_id` in every
event, read the otel ctx from the pdict when present (optional dep), follow `$callers`/`$ancestors` to the parent.

### 11. PromEx (akoutmos/prom_ex, 2ebcd0e)

Metrics, not errors: plugins turn telemetry into Prometheus series (`lib/prom_ex/plugins/`: application,
beam, phoenix, phoenix_live_view, ecto, oban, broadway, absinthe, plug_cowboy, plug_router). Exceptions
become **counters/histograms tagged by kind and normalized reason** (e.g. Broadway
`[:broadway, :processor, :message, :exception]`, `plugins/broadway.ex:44,251-259,340-347`; LiveView mount and
handle_event exceptions, `plugins/phoenix_live_view.ex:50-53`). Useful as a model for the lib's own
"system health" numbers (BEAM plugin: memory, run queue, process/port/atom counts), and as proof that
exception telemetry events are a stable public surface across these libraries. No per-error record.

### 12. Phoenix LiveDashboard (phoenixframework/phoenix_live_dashboard, 83a0bd1)

Live introspection, zero storage. Two things matter here:
- **Request logger** (`lib/phoenix/live_dashboard/logger_pubsub_backend.ex`, installed as a `:logger` handler
  in `application.ex:19-29`): a plug marks one browser's requests with the `logger_pubsub_backend` metadata
  (via a cookie), and the handler broadcasts **only log events carrying that metadata** to the dashboard.
  That is per-request log capture keyed by Logger metadata: exactly the mechanism for "logs of this request
  as breadcrumbs", done with a handler that filters by metadata instead of a per-process buffer.
- **Process page** (`system_info.ex:293-505`): `Process.info` with `:dictionary`, `:current_stacktrace`,
  `$ancestors`, `$process_label`, links, and `:sys.get_state` for OTP processes. It shows the live process;
  once it has crashed, nothing is kept. Metrics page: telemetry metrics with optional in-memory history.
  UI depends on LiveView, which 1charta does not use.

### 13. recon and observer_cli (ferd/recon cb45e7b; zhongwencool/observer_cli 04aee9f, v2.0.0)

Operator tools, no capture. Relevant pieces:
- `recon:proc_count/2`, `proc_window/3` (top N processes by memory/reductions/mailbox, windowed),
  `bin_leak/1` (`recon/src/recon.erl:267-330`), `recon:get_state/1`, `recon:info/2`: the right calls for a
  **system snapshot at crash time** (top 5 by mailbox and memory; New Relic's TopProcess sampler does the same).
- `recon_trace:calls/2,3` (`recon/src/recon_trace.erl`): rate-limited call tracing (absolute count or N per
  window, e.g. 10 per 100 ms, `:116`), via the legacy `erlang:trace/3` + `trace_pattern`
  (`:432-434`). Its `clear/0` runs `erlang:trace(all, false, [all])` and unsets **every** trace pattern
  node-wide (`:226-228`): it would silently switch off New Relic's spawn tracking or any tracer the lib
  installs on the legacy API. That is the concrete reason for the lib to use OTP 27+ `:trace` sessions
  if it traces at all (sessions are isolated from the legacy global session).
- observer_cli 2.0 (2026) re-positioned itself as "diagnostics for operators, automation, and **AI agents**"
  (`README.md:11`): a command CLI with a versioned JSON envelope `observer_cli.cli/v1` and a published JSON
  schema (`README.md:141-156`), bounded work per call, a bounded tail of a `logger_std_h` file, "one exact,
  bounded function trace with explicit node-global consent". Its trace module still sits on `recon_trace`
  (`src/observer_cli_trace.erl:443,1027`). Lesson for the agent API: versioned schema, bounded responses,
  stable exit codes.

### 14. Where breadcrumbs live: logger metadata vs process dictionary (a lesson from the issue trackers)

- Sentry 13.5.1 keeps its context and breadcrumbs **in logger process metadata** under `:__sentry__`
  (`sentry-elixir lib/sentry/context.ex:146,429`). Upside: the metadata travels with every log event into
  `:logger` handlers, including crash reports emitted in the crashing process. (Details: agent 01.)
- Honeybadger did the same until 2023: issue #475 "`:breadcrumbs_enabled` blowing up logs" (users who log
  `metadata: :all` to Datadog got multi-line JSON from the breadcrumb list) led to PR #487 "Stop using logger
  metadata for breadcrumbs", moving them to a private pdict key (`logs/02-github-issues.log`). The price is
  the gap described in section 4: its gen_event logger backend runs in another process and cannot see them.
- Tower PR #86 (2024-11) moved Bandit capture **from telemetry to the logger handler** once Bandit put
  `crash_reason` into its log metadata (bandit PR 417), and still lists "`conn` in logger metadata" as open.
  So the field is converging on "the logger handler is the one universal hook; telemetry adds context".

Design consequence: keep the ring buffer in a **private pdict key** (not logger metadata, so formatters never
print it), read it with `Process.get/1` inside the `:logger` handler when the handler runs in the crashing
process (proc_lib, gen_server, Task: all emit from the dying process, section 6), and fall back to
`report[:dictionary]` of the proc_lib crash report (which contains every pdict key) when it does not.
Agent 06/08 should prove both paths.

## Capability x tool matrix

Legend: Y = yes, automatic; P = partial or opt-in; M = manual API only; N = no; `-` = not applicable.
Sentry column is from a quick grep only; agent 01 is authoritative.

| Capability | ErrorTracker | Tower | Sentry (see 01) | AppSignal | Honeybadger | Rollbax | Bugsnag | New Relic | Scout | OTel | PromEx | LiveDashboard |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `:logger` handler / filter (process crashes) | N | Y handler | Y handler | P legacy backend | P legacy backend | P `:error_logger` | P `:error_logger` | Y primary filter | N | N (logs only) | N | logs only |
| Reads structured OTP report (not text) | - | N (needs `crash_reason`) | ? | N (needs `crash_reason`) | N (regex on text) | N (format string) | P (`error_info`) | Y | - | - | - | - |
| Plain `Logger.error` as event | N | Y (level cfg) | P (opt-in) | N | Y (default!) | P | N | N | N | log | N | log |
| Phoenix/Plug request errors | Y telemetry + Plug wrapper | Y via server crash log | Y | Y (appsignal_phoenix) | Y Plug.ErrorHandler | M | P | Y | Y | Y span event | count | - |
| LiveView | Y | via logger | Y | Y | Y (insights) | N | N | Y | Y | Y | count | - |
| Oban | Y | Y | Y | Y | Y (insights) | N | N | Y | Y | Y | count | - |
| GenServer last message + state | N | N (raw log_event passed) | ? | N | P (regex-scraped string) | P (breaks with client info) | N | N | N | N | N | live only |
| Caller stack of a crashed `call` (`client_info`) | N | N | ? | N | N | N | N | N | N | N | N | N |
| Crash report `dictionary` / neighbours | N | N | ? | N | N | N | N | P (dedupe key only) | N | N | N | live only |
| App exit (`:notice`) / supervisor max intensity | N | P (if level <= notice) | ? | N | N (error only) | P | N | N | N | N | N | N |
| Breadcrumbs | M, strings, unbounded | N | Y (logger metadata, max 100 default) | span tree | Y ring 40, Ecto + router | N | N | transaction segments | span tree | span events | N | per-request log stream |
| Crosses processes (`$callers`/trace) | N | N | ? | N (per pid) | N (documented) | N | N | Y (call trace on spawn) | N | Y (propagator reads parent pdict) | - | - |
| System snapshot | N | N | ? | minutely probe | N | N | N | minutely + top 5 procs | N | metrics | Y metrics | live |
| Client-side fingerprint | Y sha256(kind+file:line+fun) | phash2(level,kind,msg,full stack) | server | server | server (+adapter) | server | server | server | server | none | - | - |
| Storage | own DB (PG/MySQL/SQLite) | none (reporters) | SaaS | SaaS via NIF agent | SaaS | SaaS | SaaS | SaaS | SaaS | any OTLP backend | Prometheus | none |
| Async + bounded | N (sync DB write in caller) | N (sync, reporters decide) | ? | Y (native agent) | N (unbounded cast) | N (unbounded cast) | N (Task per error) | Y (reservoir 20/min) | Y (queue 500) | Y (queue 2048) | - | - |
| Self-heals if its hook is removed | N (telemetry detaches) | N | ? | N | N | N | N | N | N | N | N | N |
| UI | LiveView | none | SaaS | SaaS | SaaS | SaaS | SaaS | SaaS | SaaS | backend | Grafana | LiveView |
| Agent/API access | N (DB) | N | SaaS API + MCP (see 03) | SaaS API | SaaS API | SaaS | SaaS | SaaS | SaaS | backend | PromQL | N |

Nobody reads `client_info`, the crash report's dictionary/messages/neighbours, the `sys` debug log, or
`process_label` into the event; nobody self-heals a removed handler; only ErrorTracker stores locally; only
New Relic and OTel follow work across processes.

## Findings table

| id | what | evidence | priority | proposal (one line) | size |
|---|---|---|---|---|---|
| 02-F1 | ErrorTracker, the only self-hosted Elixir tracker, has no `:logger` handler: GenServer/Task/spawn crashes and Hologram actions are invisible | `error_tracker/application.ex:14-17`; grep for `add_handler` empty | high | the lib's primary hook is a `:logger` handler at level `:all`; telemetry only enriches | M |
| 02-F2 | Tower, AppSignal, Honeybadger depend on Elixir's translator adding `crash_reason`; Honeybadger regex-parses text and needed a second parser for Elixir 1.19 | `tower/logger_handler.ex:53-103`; `appsignal error/backend.ex:39-51`; `honeybadger logger.ex:96-186` | high | match the raw OTP report by `label` (`{proc_lib,crash}`, `{gen_server,terminate}`, `{supervisor,_}`...), use `crash_reason` only as a fallback | M |
| 02-F3 | OTP reports carry far more than anyone uses: last message, state after `format_status`, `sys` log, caller pid + stack (`client_info`), label, dictionary, received messages, neighbours | `gen_server.erl:2764-2815`; `proc_lib.erl:963-1090` | high | map these into the event as first-class "before" fields, bounded in size | M |
| 02-F4 | A handler that raises is removed by OTP forever, silently; a telemetry handler that raises is detached forever | `logger_backend.erl:54-67`; `telemetry.erl:72-124,221-231` | high | wrap `log/2` and every telemetry callback in try/catch; a supervised watchdog re-adds a missing handler and counts it | S |
| 02-F5 | Application exit is logged at `:notice`, not `:error` | `application_controller.erl:2166-2176` | medium | handler level `:all`, route by label; record app exits and supervisor `reached_max_restart_intensity` | S |
| 02-F6 | Plain-`spawn` crashes are logged by `logger_proxy`, and dropped when the proxy is in drop mode | `logger_proxy.erl:70-76,130-157` | medium | document; count drops via `[telemetry/logger] internal` if exposed; agent 04 to measure | S |
| 02-F7 | Honeybadger's breadcrumbs on logger-captured crashes come from the logger process, not the crashed one (read) | `honeybadger logger.ex:72-77` + `collector.ex` pdict | medium | read the ring in the handler via `Process.get` when `meta.pid == self()`, else from `report[:dictionary]` | S |
| 02-F8 | Breadcrumbs in logger metadata leak into log lines (`metadata: :all`) | honeybadger #475, #487 | medium | private pdict key, never logger metadata | S |
| 02-F9 | New Relic dedupes "reported manually, then crashed" through a pdict marker read back from the crash report's `dictionary` | `elixir_agent transaction/reporter.ex:105`, `error/reporter/crash_report.ex:45` | high | same trick: put `{fingerprint, ref}` in the pdict when telemetry/Plug reports; skip the crash report that carries it | S |
| 02-F10 | Cross-process "request chain" is solved two ways: NR's call tracing on spawn (global tracer, collides with recon's `clear/0`) and OTel's parent-pdict read via `$callers`/`$ancestors` | `erlang_trace.ex:78-110`; `recon_trace.erl:226-228`; `opentelemetry_process_propagator.erl:10-49` | high | default: `$callers`/`$ancestors` + parent pdict read (no tracing); optional OTP 27+ trace session later | M |
| 02-F11 | Fingerprints in the field are fragile: ErrorTracker includes `file:line`; Tower hashes message + full stack with lines | `error.ex:43-66`; `event.ex:220-248` | high | fingerprint = kind + exception module + in-app frames as `{module, function, arity}` without lines (agent 08) | S |
| 02-F12 | Most clients have no memory bound: ErrorTracker writes synchronously, Honeybadger/Rollbax cast to one GenServer, Bugsnag spawns a Task per error; only Scout (queue 500), NR (20/min reservoir), OTel logs (2048) bound it | sections 1, 4, 5, 7, 8, 10 | high | bounded buffer with drop counter + per-fingerprint rate limit; never block the caller | M |
| 02-F13 | `format_status/1` is OTP's hook to redact GenServer state in crash reports; the report already applied it | `gen_server.erl:2764-2771` | medium | trust report state (already redacted); document "implement `format_status/1` to hide secrets"; add key-based scrubbing on top | S |
| 02-F14 | LiveDashboard's request logger shows per-request log capture by metadata filter | `logger_pubsub_backend.ex`, `application.ex:19-29` | low | same idea for "log lines of this request" as breadcrumbs, with a ring buffer instead of PubSub | S |
| 02-F15 | observer_cli 2.0 targets AI agents with a versioned JSON envelope + schema and bounded calls | `observer_cli README.md:11,141-156` | medium | give the lib's agent API a versioned schema (`blackbox.v1`), bounded responses, stable error codes | S |
| 02-F16 | Resolve-reopens-on-recurrence, mute, pruner and versioned migrations in ErrorTracker are good and cheap | `error_tracker.ex:156-208,346-354`; `plugins/pruner.ex`; `migration/postgres/v01..v05` | medium | copy the issue/occurrence model and migration style; retention for all rows, not only resolved | S |

## Recommendations for the lib

1. **One `:logger` handler as the spine**, `level: :all`, id `:blackbox`, with a domain filter that stops its own
   domain `[:blackbox]` (Tower's trick) so its internal warnings never loop back. Everything inside `log/2` in
   `try/catch`; the handler only classifies and hands off a bounded term, never does I/O.
2. **Classify by report label, not text**: `{proc_lib,crash}`, `{gen_server,terminate}`, `{gen_statem,terminate}`,
   `{gen_event,terminate}`, `{supervisor,child_terminated|start_error|shutdown|shutdown_error}`,
   `{application_controller,exit}` (at `:notice`), then `crash_reason` metadata (Bandit/Cowboy/Elixir translator),
   then plain `:error`+ messages as "log errors" (opt-in by level, Honeybadger's `sasl_logging_only` switch
   inverted). Unknown shapes: keep as "unrecognized" events, as Tower does, never drop silently.
3. **Mine the OTP reports** for "before" data nobody uses: `last_message`, `state` (already passed through
   `format_status/1`), `log` (sys debug log), `client_info` (caller pid + stack: links the GenServer crash to the
   request that called it), `process_label`, `messages`, `message_queue_len`, `dictionary` (`$callers`,
   the lib's ring buffer), `links` and neighbour summaries. Bound each with a byte budget (`:erts_debug.flat_size`
   check, then `inspect` with `limit`/`printable_limit`).
4. **Breadcrumbs in a private pdict ring** (N=50 default, typed `{ts, category, message, data}`), never in logger
   metadata. Default sources: Phoenix router dispatch, Ecto queries, Req/Finch requests, Logger calls below the
   reporting level (agent 06 measures), Oban job start. Read in the handler with `Process.get` when
   `meta.pid == self()`, else from `report[:dictionary]`.
5. **Request chain** without tracing: follow `$callers` then `$ancestors` to a live parent and read its ring and
   context via `Process.info(parent, :dictionary)` (OTel propagator's trick), plus `client_info` for calls. Tracing
   (OTP 27+ sessions, never the legacy global tracer that `recon_trace:clear/0` wipes) is an optional later step.
6. **Dedupe** two views of one failure with a pdict marker set by the telemetry/Plug path and found again in the
   crash report's `dictionary` (New Relic), plus a short time-window key `{pid, fingerprint}` for the Bandit log +
   telemetry pair; ignore `plug_status < 500` by default.
7. **Handler hand-off**: `log/2` does a cheap non-blocking insert into a bounded buffer (ETS counter + drop
   counter), a writer process batches to Postgres. Per-fingerprint rate limit. Numbers from agent 08.
   Beat the field's worst cases: no sync DB write in the caller (ErrorTracker), no unbounded cast (Honeybadger,
   Rollbax), no Task per error (Bugsnag).
8. **Self-healing**: a supervised watchdog checks `:logger.get_handler_config(:blackbox)` and the telemetry
   handlers every few seconds and re-attaches, emitting an internal "capture was off for N s" event.
9. **Fingerprint** without line numbers or messages: kind + exception module (or exit reason shape) + in-app
   `{m, f, a}` frames; store `file:line` on the occurrence only.
10. **Storage model from ErrorTracker**: `issues` (fingerprint unique, status, muted, first/last seen, count) and
    `occurrences` (event JSON, breadcrumbs JSON, context), upsert on fingerprint, resolved reopens, versioned
    migrations installed by a mix task; retention prunes occurrences per issue and old issues, not only resolved.
11. **Reporter behaviour** (Tower's idea) so the same event can later be forwarded to a Sentry-compatible endpoint
    or OTLP; a failing reporter never receives its own failure (Tower's `ReportEventError` guard).
12. **System snapshot at capture time**, cheap subset: `:erlang.memory/0`, run queue, process count vs limit, top 5
    by mailbox (recon/NR TopProcess style, sampled every few seconds into ETS, not computed per error).
13. **Agent API** with a versioned JSON schema and bounded responses (observer_cli 2.0), plus `trace_id`/`span_id`
    fields populated from the OTel ctx when that optional dep is present.

## Sources

All repos cloned 2026-09-27 into the session scratchpad `src/`; hashes in `logs/02-clones.log`.
- elixir-error-tracker/error-tracker 630ea49 (v0.9.0): `lib/error_tracker.ex`, `lib/error_tracker/{application,schemas/error,schemas/stacktrace,integrations/phoenix,integrations/plug,integrations/oban,plugins/pruner,telemetry}.ex`
- mimiquate/tower 057aa00: `lib/tower.ex`, `lib/tower/{logger_handler,event,oban_exception_handler,ephemeral_reporter,application}.ex`
- appsignal/appsignal-elixir 4aef537 (2.17.5): `lib/appsignal/{error/backend,tracer,monitor,logger/handler,probes/erlang_probe,config,utils/logger_handler}.ex`
- honeybadger-io/honeybadger-elixir 1eaf148 (0.30.1): `lib/honeybadger.ex`, `lib/honeybadger/{logger,client,plug,fingerprint_adapter}.ex`, `lib/honeybadger/breadcrumbs/*.ex`, `lib/honeybadger/insights/*.ex`
- ForzaElixir/rollbax 5ea0ab4 (0.11.0); bugsnag-elixir/bugsnag-elixir 0e1e2ba (3.0.2)
- newrelic/elixir_agent e2a0e33 (1.42.0): `lib/new_relic/error/{logger_filter,reporter/crash_report}.ex`, `lib/new_relic/transaction/{erlang_trace,reporter}.ex`, `lib/new_relic/sampler/{beam,top_process}.ex`, `lib/new_relic/harvest/collector/error_trace/harvester.ex`, `lib/new_relic/signal_handler.ex`
- scoutapp/scout_apm_elixir d7ae4a5 (2.1.0); spandex-project/spandex a40c10a
- open-telemetry/opentelemetry-erlang 9cb8b36 (`apps/opentelemetry_api/src/otel_span.erl`, `apps/opentelemetry_experimental/src/otel_log_handler.erl`); opentelemetry-erlang-contrib 0cbae53 (`propagators/opentelemetry_process_propagator`, `instrumentation/opentelemetry_{phoenix,bandit,oban}`)
- akoutmos/prom_ex 2ebcd0e; phoenixframework/phoenix_live_dashboard 83a0bd1; ferd/recon cb45e7b; zhongwencool/observer_cli 04aee9f (2.0.0)
- beam-telemetry/telemetry (`src/telemetry.erl`)
- erlang/otp de741b7 (main, 30.0-rc0): `lib/stdlib/src/{proc_lib,gen_server,supervisor,gen_statem,gen_event}.erl`, `lib/kernel/src/{logger,logger_backend,logger_proxy,logger_server,logger_handler_watcher,application_controller}.erl`, `lib/kernel/src/logger_olp.hrl`
- getsentry/sentry-elixir edb3ecf (13.5.1), grep only: `lib/sentry/context.ex:146,429`, `lib/sentry/config.ex:473-478`
- GitHub issues (API, `logs/02-github-issues.log`): honeybadger-elixir #475, #487; tower #86
