# BRIEF: research for ADR 0031, an error tracker for the BEAM

Read this first, all of it. You are one of eight research agents. The lead
(session 1charta-a6 [d7a158]) writes ADR 0031 and one research page from
your reports. (ADR 0030 belongs to a peer session; do not touch
`docs/research/0030-*`.)

## What the user asked (verbatim, 2026-09-27)

> as a new lib (kept inside this repo for now, planned to be a separate hex
> package)
>
> we want to build the most useful and amazing error/exception/bug tracking
> observibility tool for elixir there ever could be. it should get ALL errors
> that occur in the beam. sync and async, listening to phoenix but also
> everything else. have a look at the sentry for elixir package, how do they
> do? we also want to track more additional information, especially what
> happenened before any given error. make an enoourmous reserach effort here
> and prove TDD everything technical that is not clear. write an ADR/research
> artifact.

So, four things: (1) catch EVERY failure on the BEAM, not just Phoenix
requests (processes, tasks, GenServers, supervisors, casts, timeouts, exits,
Logger.error, the VM itself); (2) how sentry-elixir (and every other tool)
does it and what they miss; (3) capture *what happened before* each error
(breadcrumbs, the request/job/message chain, the process's recent history,
state, system health); (4) **prove every unclear technical claim with a test**
(see TDD protocol below). Working name of the lib: `blackbox` (a flight
recorder: it keeps what happened before the crash). Agent 07 checks names.

Context: **1charta** (in prose; module names stay `Charta`) is the user's own
tool first: a hackable whiteboard + Markdown Spaces, Elixir 1.20.4 / OTP 28,
Phoenix 1.8 + Bandit + **Hologram** (not LiveView), Ecto/Postgres, Req/Finch.
Coding agents (Claude Code) work on it all day through an API/sidecar
(ADR 0012, 0017). The lib must NOT depend on Hologram or 1charta: it is a
general hex package, used by 1charta first. It lives in this repo for now.

## TDD protocol for the labs (agents 04, 05, 06, 08; others where useful)

"Prove TDD" means: every technical claim that is not obvious becomes an
ExUnit test **written before you run it**, with the assertion you expect.
Run it. Record the first outcome (red or green) in your report's claims
table. If red, the claim was false: note what really happens, then change the
assertion to the observed behaviour, so the finished suite is a green,
executable spec of BEAM facts. Name tests `"NN-k: <claim in words>"`. Paste
the final `mix test` summary line (and seed) into your log. Tests must be
deterministic: run the suite 3 times; flaky = say so. Measure costs with
`:timer.tc` loops or Benchee (allowed as a lab dep) and give numbers with the
machine (`sysctl -n machdep.cpu.brand_string`).

## Lab setup (binding)

- Each lab is a standalone Mix project: `docs/research/0031-errors/lab/NN-<name>/`
  created with `mix new` (own `_build`, own `deps`; `lab/.gitignore` already
  ignores them). Hex deps are allowed in labs (phoenix, bandit, plug_cowboy,
  phoenix_live_view, ecto_sql, postgrex, oban, req, telemetry, benchee, ...).
- **Never run mix in the repo root** (no `mix test`, `mix compile`,
  `mix holo`, `mix run` there): it rewrites Hologram bundles and breaks the
  user's running dev server. `cd` into your lab dir first, every time.
- **Ports:** never :4000 or :4010. Lab HTTP servers only on 4310-4399, started
  and stopped inside ExUnit (`start_supervised`). No detached `&` subshells.
- **Postgres:** localhost:5432, user `postgres`, trust auth. Use only a
  database named `lab_0031_NN` (create/drop it yourself). Run mix in the
  foreground of your Bash call (Postgres.app blocks detached processes).
- Do not modify `/Users/lennartbuttner/Projects/1charta/erl_crash.dump`
  (agent 07 reads it; copy it if you need it).

## Rules (all agents, binding)

1. **Git is read-only.** `git log/diff/show/status/blame` only. Never add,
   commit, stash, checkout, reset, restore, worktree. Other sessions work here.
2. **Edit no code outside `docs/research/0031-errors/`.** Write only your
   report, `logs/NN-*`, `shots/NN-*`, `lab/NN-*/`.
3. **Never pkill or killall.** Stop only what you started.
4. **Write incrementally.** Create your report in your first five minutes with
   the outline, then append after EACH source read or experiment by Bash
   heredoc (`cat >> file <<'EOF2'`; the Write tool may be blocked for you).
   Log raw commands and numbers to `logs/NN-*.log`. What is on disk is all
   that survives if you die. A report that sits at 20 lines for an hour is a
   failure even if the work is good.
5. **Web budget: at most 12 WebSearch calls each** (one shared budget for all
   eight). Prefer: `git clone --depth 1` of GitHub repos into
   `/private/tmp/claude-501/-Users-lennartbuttner-Projects-1charta/716f9269-0646-4458-aef1-e4c19dc5a01f/scratchpad/src/`
   (check if a peer already cloned it there first), `mix hex.package fetch
   <pkg> --unpack --output <dir>`, WebFetch on hexdocs.pm, raw.githubusercontent.com,
   the GitHub API (issues search: api.github.com/search/issues?q=repo:getsentry/sentry-elixir+...),
   elixirforum.com (`.json` suffix on topic URLs), HN Algolia API
   (hn.algolia.com/api/v1/search?query=...), reddit `.json`, erlang.org docs
   (the OTP source is also at github.com/erlang/otp).
6. **Do not delegate** to sub-agents.
7. Sources: a URL or `file:line` (with version/commit) for every claim that
   matters. Mark **verified** (you ran it) vs **read** (source/docs). Say
   "unknown" rather than guess. Today is 2026-09-27.
8. **Report shape:** `# NN title`, **Summary for the lead** on top (10 lines,
   ranked), body, **Claims table** for labs (id `NN-k`, claim, first run
   red/green, final truth, test name), **Findings table** (id, what, evidence,
   priority, proposal in one line, size S|M|L), **Recommendations for the
   lib** (numbered, concrete), **Sources**. 300 to 900 lines.
9. Final reply to the lead: the file path and the ten summary lines.

## What the ADR must decide

A. **Capture surface.** Which hooks together see ALL failures: an OTP
   `:logger` handler (crash reports, supervisor reports, `Logger.error`),
   `:telemetry` exception events (Phoenix, Plug, Bandit, Ecto, Oban, ...),
   Plug wrapper, process monitors, `:erlang.system_monitor`, trace sessions
   (OTP 27+ `:trace`), alarms, `erl_crash.dump` on next boot, node down.
   What each sees that the others miss; how to dedupe one failure seen twice.
B. **What happened before.** Breadcrumbs (which sources, how many, per
   process or per request chain via `$callers`/`$ancestors`/Logger metadata),
   the GenServer's last message + state, `:sys` debug log, the request/job,
   recent telemetry spans, system health at the moment, the deploy/version.
   Costs in µs and bytes per request, measured.
C. **Event model and grouping.** Fields, stacktrace depth
   (`:erlang.system_flag(:backtrace_depth, ...)`), source context, fingerprint
   that survives line shifts, occurrences vs issues, scrubbing secrets.
D. **Safety.** The tracker must never take the app down or slow it: handler
   crash = OTP removes it; floods (10k errors/s); logger overload; DB down;
   recursion (an error while reporting an error); memory bounds.
E. **Storage and transport.** Self-hosted in the app's own Postgres (like
   ErrorTracker) vs ETS/disk vs sending to Sentry-compatible endpoints;
   retention; what 1charta needs.
F. **The UI and the agents.** What the "most useful" view shows (timeline of
   what happened before); where it lives without depending on LiveView or
   Hologram; an API/MCP so coding agents can read and resolve errors.
G. **Packaging.** In-repo path dep now (where: `packages/blackbox`?), hex
   later; optional deps; config; the name; how 1charta wires it in.
H. **Order of work** and the tests that prove each step.

## Agents and their files (write only your own)

01 `01-sentry.md` — sentry-elixir, deep source read (latest release + main):
   `Sentry.LoggerHandler` (what it filters: crash reports only? levels,
   `capture_log_messages`, rate limiting, `:excluded_domains`), `PlugCapture`,
   `PlugContext`, Phoenix endpoint integration, Oban/Quantum integrations,
   `Sentry.Context` and breadcrumbs (what is automatic, what is manual,
   per-process storage), event building, stacktrace + source context
   (`mix sentry.package_source_code`), fingerprinting (server-side), dedup
   (`Sentry.Dedupe`), sampling, transport/sender pool, test mode, tracing/OTel
   support, what happens when Sentry is down. Then its GitHub issues: what
   users say is missed or noisy (count them). What we copy, what we do better.
02 `02-elixir-field.md` — every other BEAM tool, source-read: ErrorTracker
   (elixir-error-tracker: self-hosted, Postgres/SQLite, LiveView UI, telemetry
   + logger), Tower (mimiquate/tower, reporter-agnostic), AppSignal, Honeybadger
   (breadcrumbs, insights), Rollbax, Bugsnag, New Relic elixir_agent,
   Scout, opentelemetry-erlang/elixir (exception recording, span events),
   Datadog/Spandex, PromEx, Phoenix LiveDashboard, recon/observer_cli,
   Erlang's logger internals and OTP's own crash report format. Per tool: the
   capture hooks, what "before" data, storage, UI, what they miss. A
   capability × tool matrix.
03 `03-field-and-ux.md` — beyond Elixir: the best error trackers' "what
   happened before" and UX (Sentry breadcrumbs/traces/session replay/Seer AI,
   Rollbar telemetry, Bugsnag breadcrumbs, Honeybadger, BetterStack, Highlight,
   PostHog error tracking, Datadog error tracking, Bugsink/GlitchTip self-host,
   Replay.io / rr / Pernosco time travel, "wide events" (Honeycomb, Charity
   Majors), flight recorders (JFR, Go's runtime/trace FlightRecorder)).
   Grouping algorithms (Sentry's grouping docs), noise/alert fatigue, what
   developers love and hate (counted quotes from HN, Reddit, ElixirForum),
   error trackers for AI coding agents (Sentry MCP, Seer). Design rules.
04 `04-beam-surface-lab.md` — LAB. Every way a BEAM process can fail and
   exactly what reaches a `:logger` handler (level, domain, report shape,
   metadata incl. `crash_reason`, `mfa`, `pid`, `$callers`): raise/throw/exit
   in `spawn`, `spawn_link`, `Task.start`, `Task.async`+`await` (both sides),
   `Task.Supervisor.async_nolink`, GenServer init/call/cast/info/terminate,
   call timeouts (caller side), Agent, `:gen_statem`, supervisor restarts and
   max-intensity shutdown, application stop, `exit(:kill)`, brutal kill,
   `{:shutdown, _}`, `:normal`, trapped exits, BIF badarg, `Logger.error`
   without a crash, `:erlang.error` in a NIF-free BIF, process labels (OTP 27
   `Process.set_label`), stack depth truncation (`backtrace_depth`), what the
   crash report carries (dictionary, message queue, links, last message +
   state, `:sys` debug log). Then the silent ones: rescued-and-swallowed
   exceptions, `{:error, _}` returns, `catch :exit`: can trace sessions with
   `exception_trace` see them, at what cost? Handler safety: a handler that
   raises gets removed (prove), logger overload/drop under a flood (prove the
   numbers), handler running in the caller's process (prove).
05 `05-frameworks-lab.md` — LAB. Phoenix 1.8 + Bandit (and Plug.Cowboy for
   contrast), Plug, Phoenix channels/sockets, LiveView (the lib must support
   it even though 1charta uses Hologram), Ecto/Postgrex (query errors,
   DBConnection disconnects, pool timeouts, transaction rollbacks), Oban
   (failed/discarded/snoozed jobs), Req/Finch (HTTP failures), Hologram
   (read 1charta's deps/hologram source for how actions/commands fail on the
   server, do not run it). Per framework: what the logger handler sees,
   which telemetry exception events fire and their metadata (conn, params,
   route, socket, query, job), 404/NoRouteError and other "expected"
   exceptions (plug_status), double-reporting between logger and telemetry
   and how to dedupe, how to get the request (conn) into the event.
06 `06-before-lab.md` — LAB + benchmarks: capturing what happened before.
   Breadcrumbs from Logger below the configured level (primary level vs
   handler level, cost of Logger.debug when primary is :debug), per-process
   ring buffers (process dictionary vs ETS vs a GenServer), linking a crash
   in a Task/GenServer back to the request via `$callers`/`$ancestors`/
   Logger metadata, telemetry events as breadcrumbs (attach to known event
   names; cost per event), OTP 27+ trace sessions to record the last N
   calls/messages/spawns of a process (cost, safety), `seq_trace`,
   `:sys` debug log on GenServers, capturing GenServer state/last message,
   system snapshot at crash time (memory, run queue, schedulers,
   `:erlang.statistics`), mailbox growth and long_gc via `system_monitor`,
   OpenTelemetry trace/span ids. Numbers: µs and bytes per request/event,
   p50/p99 overhead on a Plug request.
07 `07-source-and-packaging.md` — 1charta today and packaging: how 1charta
   logs and fails today (`config/*.exs` logger, `Charta.Application` tree,
   endpoints, Hologram error handling in `deps/hologram`, the sidecar, the
   agent API), the `erl_crash.dump` in the repo root (what killed it?), prod
   reality READ-ONLY if the ssh works (`ssh -i ~/.ssh/id_ed25519_hetzner
   root@188.34.181.56 'cd /opt/charta && docker compose logs --since 168h app
   | grep -c ...'`: counts and error kinds only, no personal data; if the
   call is refused, skip it), the Dockerfile's OTP version, releases and
   source context. Packaging: path dep in this repo (`packages/<name>`?),
   Hologram's compiler vs a path dep, config, optional deps, hex name
   availability (hex.pm API `https://hex.pm/api/packages/<name>` for 15
   candidate names: blackbox, black_box, flight_recorder, postmortem,
   tombstone, ...), how an agent (Claude Code) would read errors (API, MCP,
   files like ADR 0012's sidecar).
08 `08-core-spike.md` — LAB: a minimal end-to-end spike of the core, TDD:
   (a) a `:logger` handler + telemetry attach that turns every failure
   into one normalized event (exception/kind, stacktrace, pid, label, mfa,
   metadata) with a fingerprint that survives line shifts; (b) a bounded,
   non-blocking pipeline (handler -> buffer -> writer) that survives floods
   (10k errors/s: memory flat, app latency unchanged), a crashing writer,
   the DB being down, and recursive errors inside itself; (c) storage in
   Postgres (issues + occurrences, upsert by fingerprint) with a count of
   rows and write latency; (d) breadcrumbs attached from a per-process ring
   buffer. Measure everything. Read 04 and 06 as they land and reuse their
   facts; do not redo their taxonomy.
