# 06 What happened before: capture mechanisms, proven and measured

Status: done 2026-09-27. Agent 06 (lab + benchmarks).

## Summary for the lead

1. **Per-process pdict ring is the crumb store** (42 ns/add, 4.4 KB for 50): every proc_lib crash (GenServer, Task, Bandit conn) is logged *from the dying process*, so the handler reads its ring for free; a single GenServer ring drowned (8.5M queued msgs in 3 s), an ETS ring leaked 59 MB of dead-pid rows.
2. **Full capture costs ~5 µs p50 / ~45 µs p99 per request in-process, invisible over HTTP** (M3 Pro, Bandit, 5 debug logs + 3 queries + 1 call); almost all of it is flipping primary Logger level to `:debug`, not the crumbs (~1.8 µs).
3. **So Logger debug crumbs must be opt-in;** telemetry crumbs (125 ns each) + `:info`+ logs are the default. Per-process debug sampling is impossible (`put_process_level` can only drop, RED 06-47); per-module levels work.
4. **seq_trace label = zero-code request id** across call, cast, send and spawn (+128 ns per call), readable in the crash handler of any process that crashed while serving it; spawned processes inherit it (RED 06-25), so reset it per request and in the lib's own processes.
5. **Bandit reuses one process per keep-alive connection:** ring and label must be reset on `[:bandit, :request, :start]`, or request N's crumbs show up in N+1's crash.
6. **GenServer crashes inside `call` name the caller and its stack** (`client_info`, and `last_message` is the bare request, RED 06-12); casts lose the sender (the label keeps it). `$callers` links Tasks; `$ancestors` is only the supervision tree.
7. **Elixir drops the proc_lib crash report (with dictionary, links, queue) for all handlers by default** (primary translator filter, `sasl: false`, RED 06-9): the lib must read that context itself in the handler.
8. **`:sys.log` is a built-in per-GenServer flight recorder** (+56 ns/call, switchable at runtime, lands in the terminate report's `log`), but it leaks secrets that `format_status` scrubbed from `state` (06-35): the lib must scrub `log` too.
9. **OTP 28 `trace:system/3` gives per-session system monitors** (long_message_queue, large_heap...), fixing the one-owner-per-node `system_monitor` (06-32); trace sessions coexist with dbg/recon, receive tracing is ~free, call tracing +271 ns/call, and tracers are never throttled (>50k queued in 500 ms): on-demand only.
10. **Snapshot at crash: take only sub-µs fields** (run queue 0.02 µs, process count, process info 0.08 µs); `:erlang.memory()` 47 µs, `ets.all` 34 µs and `statistics(:io)` 35 µs belong in a 1 s sampler. 52 tests, 7 red on first run (5 wrong beliefs, 2 test bugs), final suite green 3x. Joins proven: own ring, `$callers` (async_nolink), `client_info` (call into long-lived server), label only (cast, orphaned tasks).

## Machine and method

- Machine: Apple M3 Pro (`sysctl -n machdep.cpu.brand_string`), 11 cores, macOS 15 (Darwin 24.6.0).
- Elixir 1.20.4 on Erlang/OTP 28 (erts 16.4.0.6).
- Lab: `docs/research/0031-errors/lab/06-before/` (`mix new`, deps: benchee, telemetry, plug, bandit, req, opentelemetry_api).
- Every claim below is an ExUnit test named `06-k: ...`, written before its first run; the first outcome is recorded
  in the claims table. Red tests were changed to assert the observed behaviour. Raw output in `logs/06-*.log`.
- Costs: Benchee (`bench/*.exs`, 1 s warmup, 3 s run, 1 s memory) or `:timer.tc` loops; bytes via
  `:erts_debug.flat_size/1 * 8` (heap words) and `:erlang.external_size/1` (wire size).

## Experiments

(Restored note: a report-assembly script cut these sections once; they were rewritten from the run logs the same
hour. All numbers come from `logs/06-*.log`.)

### Experiment A: breadcrumbs from Logger, below the configured level

Test file `lab/06-before/test/a_logger_test.exs`. All 7 green on the first run.

- **Primary level is a hard gate.** With `:logger` primary level `:info`, `Logger.debug` never reaches any handler,
  not even one registered at level `:all` (06-1). So "breadcrumbs from debug logs" needs primary level `:debug`
  (or a per-module level, 06-5), and every *other* handler (console, file) must then carry its own `level: :info`
  so the output does not change (06-2: handler levels filter independently; a debug event reaches only the `:all` handler).
- **The handler runs in the caller** (06-3). A breadcrumb handler therefore sees `self()` = the logging process,
  and can write to that process's own dictionary: a per-process ring with no shared state and no message (06-6).
- **Disabled calls are free of argument evaluation** (06-4): the Elixir macro checks the level before building
  the message, so `Logger.debug("#{inspect big}")` costs nothing when off.
- Ring buffer shape used everywhere below: `{count, newest-first list}` in the pdict, trimmed to 50 when it hits
  100 (amortised O(1), 06-7).

#### Costs (Benchee, `bench/logger.exs`, log `logs/06-bench-logger.log`, M3 Pro)

| Call | median | p99 | alloc per call |
|---|---|---|---|
| `Logger.debug` with primary `:info` (off) | 25 ns | 46 ns | 24 B |
| `Logger.debug` with primary `:debug`, console handler at `:info` only | 500 ns | 709 ns | 1.13 KB |
| same + crumb handler writing the pdict ring | 750 ns | 1.54 µs | 2.36 KB |
| same + crumb handler writing the ETS ring | 834 ns | 1.17 µs | 2.45 KB |
| `Ring.Pdict.add` alone (1 process) | 42 ns | 375 ns | 0 B |
| `Ring.Ets.add` alone (1 process) | 250 ns | 334 ns | 56 B |
| `Ring.Server.add` (GenServer cast) alone | 166 ns | 375 ns | 56 B |
| 8 parallel writers: pdict / ETS / cast | 21 ns / 290 ns / 250 ns | 12.8 µs / 0.54 µs / 1.33 µs | |

Bytes: a full `:logger` event is 256 heap bytes (166 external); a compact crumb `{time, level, msg}` is 56 B;
a full ring of 50 crumbs with ~25-char messages is 4.4 KB of the owning process's heap.

What this means:

- Turning primary level to `:debug` costs ~0.5 µs per debug call site *that already exists in the app and its deps*
  (Ecto, Bandit, Finch log at debug), even with no extra handler. The crumb itself adds only ~0.25-0.33 µs.
  So the real price of "Logger breadcrumbs" is the app's debug call volume x 0.8 µs. For a request with 20 debug
  calls: ~16 µs. Cheap, but not free, and it depends on the deps' chattiness (see G and H for the p99 effect).
- **The GenServer ring is a trap.** The cast looks cheap to the sender (166 ns) but after 3 s of 8 parallel
  writers the server had **8,560,997 messages queued** (logged). One process cannot absorb app-wide crumbs.
  Rejected.
- **The ETS ring leaks without cleanup:** after the Benchee runs (which spawn fresh processes) the table held
  371,920 rows / 59 MB for dead pids. An ETS ring needs a monitor or a sweeper per pid; the pdict ring is
  freed with the process by the VM for free.
- pdict ring p99 under parallel load (12.8 µs) is the trim + GC of the owning process, amortised.

### Experiment B: context at the moment of the crash (which process logs it, what the report carries)

Test file `lab/06-before/test/b_crash_context_test.exs`. First run 8/10; two red (06-9, 06-12), fixed to the truth.

- **proc_lib crashes are logged by the dying process itself** (06-8): for a GenServer (and Task, 06-10) the
  handler's `self()` is the crashed pid, so the handler can read the crashed process's own pdict ring at that
  moment. This is the cheapest possible "what happened before": no shared table, no copy until a crash.
- **A plain `spawn` crash is logged elsewhere** (06-11): the handler runs outside the dead process, whose
  dictionary is already gone (`Process.info(pid, :dictionary) == nil`). Raw `spawn` needs an ETS ring (or nothing).
- **RED 06-9: Elixir drops the proc_lib crash report for every handler.** Elixir installs a *primary* filter
  `logger_translator` with `sasl: false` (from `config :logger, handle_sasl_reports: false`, the default; seen in
  `:logger.get_primary_config()`). The `{:proc_lib, :crash}` report, which carries the full process dictionary,
  message queue, links and ancestors, never reaches any handler, not even one at `:all`. With `sasl: true` it
  arrives and the dictionary includes our ring key. The lib should not depend on it: the pdict can be read directly
  in the handler (06-8), and flipping `handle_sasl_reports` also turns on console noise (supervisor progress reports).
- **RED 06-12: `last_message` of a crashed `call` is the bare request** (`:crash`), not the `{:"$gen_call", from, msg}`
  envelope; the caller is in `client_info = {caller_pid, {caller_pid, caller_stacktrace}}`. So a GenServer
  crash inside a request *does* name the request process, and its current stack. A cast crash keeps the envelope
  `{:"$gen_cast", msg}` and `client_info: :undefined` (06-13): casts lose the sender.
- `state` is in the report, already passed through `format_status/1` (06-14): the GenServer author's own scrubbing
  hook works, and the lib should honour it (never call `:sys.get_state` behind its back at crash time).
- `$callers` crosses into Tasks, Logger metadata does not (06-15). So linking a Task crash to the request needs
  `$callers` -> the parent's ring, read with `Process.info(parent, :dictionary)` from the handler (06-10).
- Logger metadata set *inside* a GenServer rides on its crash event's `meta` (06-16): a cheap per-process context
  slot, e.g. `Logger.metadata(board_id: id)` in `init/1`.
- `$ancestors` of a GenServer names the process that started it (06-17), never the request that called it:
  ancestry is the supervision tree, not causality. Causality comes from `client_info` (calls), `$callers` (Tasks),
  or explicit propagation (seq_trace label, Experiment D).

### Experiment C: telemetry events as breadcrumbs

Test file `lab/06-before/test/c_telemetry_test.exs`, all 4 green first run. Bench `bench/telemetry.exs`
(log `logs/06-bench-telemetry.log`).

- Telemetry handlers run in the emitting process (06-18), same as Logger handlers: an Ecto query, a Finch request
  or a Bandit request stop event can be written into *that* process's pdict ring with no messaging.
- A raising handler is detached for good and `[:telemetry, :handler, :failure]` fires (06-19). The lib must
  watch that event for its own handler ids and re-attach (or at least report it), or breadcrumbs silently stop.
- No wildcard/prefix attach (06-20): the lib needs a list of known event names (Phoenix, Plug, Bandit, Ecto repo
  prefix from config, Finch, Req, Oban, Absinthe...). `:telemetry.list_handlers([])` shows every event someone else
  attached to (06-21), a useful discovery aid for a "which events exist in this app" page, but not complete
  (events with no handler are invisible).

| `:telemetry.execute` | median | p99 | alloc |
|---|---|---|---|
| 0 handlers | 83 ns | 125 ns | 32 B |
| 1 no-op handler | 83 ns | 167 ns | 144 B |
| 1 handler -> pdict ring | 125 ns | 458 ns | 144 B |
| 1 handler -> ETS ring | 292 ns | 625 ns | 232 B |

A telemetry crumb `{t, event, measurements}` is 128 heap bytes; keep metadata out of the crumb (Ecto's metadata
holds the full query, params and result: copy only the few fields worth showing, scrubbed).
Telemetry crumbs are ~6x cheaper than Logger crumbs (125 ns vs 750 ns) because there is no level check,
metadata merge or translator filter in the path.

### Experiment D: a request id that follows messages by itself (seq_trace label)

Test file `lab/06-before/test/d_seq_trace_test.exs`; first run 4/6, bench `bench/seq_trace.exs`
(log `logs/06-bench-seq_trace.log`).

`:seq_trace.set_token(:label, request_id)` with no trace flags sets a token that the VM attaches to every message the
process sends; the receiver's token becomes the message's token on receive. No tracer is involved, so nothing is
traced: it is pure baggage.

- The label (any term, here a binary) travels into a GenServer with `call` (06-22), `cast` and plain `send` (06-24).
  Casts lose the sender in the crash report (06-13); the label does not.
- A later message without a token clears it (06-23): a shared GenServer serving many requests sees the right label
  per message, no leak. (First run was red only because the "clean" caller was a Task that had inherited the test's
  label; see 06-25.)
- **RED 06-25: spawned processes inherit the label**, Task and raw `spawn` alike. Good for us: work spawned from a
  request is labelled without `$callers`. Also a trap: a long-lived process *started* inside a request (a lazily
  started GenServer, a Registry-backed room) carries that request's label until its first untokened message.
- The crash handler of a GenServer that crashed inside a labelled call reads the label (06-26), because the handler
  runs in the crashing process. So every crash of a process doing work for a request can name the request id,
  across call/cast/send/spawn, with zero code in the app.
- The reply brings the label back and it stays set in the caller (06-27): a keep-alive connection process must
  clear it (`:seq_trace.set_token([])`) at the end of each request (see Experiment G).

| (1,000,000 iterations, median of 5 runs) | ns per op |
|---|---|
| `GenServer.call` round trip, no label | 878 |
| same, label `"req-0123456789"` | 1006 (+128 ns, +15%) |
| same, label a 1 KB map | 2234 (label is copied into every message: keep it tiny) |
| `set_token(:label, id)` | 23 |
| `get_token(:label)` | 199 |

Caveats (read, not tested): `seq_trace` is a single, VM-wide facility. If any other tool on the node sets a
system seq tracer *and* sets trace flags on a token, our labelled messages could be traced. Labels only (no flags)
emit nothing. Whether anything in the Elixir ecosystem uses seq_trace labels: unknown (none seen in this lab's deps).

### Experiment E: the GenServer's own log, system health, system_monitor, OTel ids

Test files `lab/06-before/test/e_sys_test.exs` (7, all green first run) and `test/e2_sys_scrub_test.exs` (1, green).
Benches `bench/sys.exs`, `bench/snapshot_fields.exs` (logs `logs/06-bench-sys.log`, `logs/06-bench-snapshot-fields.log`).

- **`:sys` debug log is a built-in flight recorder per GenServer.** Start with `debug: [log: 10]` (06-28) or switch it
  on at runtime with `:sys.log(pid, {true, 10})` (06-29) and the `{:gen_server, :terminate}` report carries the
  last N system events (`{:in, msg}`, `{:out, reply, to}`, `{:noreply, state}`) in its `log` field; off, `log: []`
  (06-30). Cost: `call` 836 ns -> 892 ns (+56 ns, +7%) with 10 entries, 899 ns with 50. Cheap enough to turn on for
  the handful of GenServers that matter (board servers, sidecar), and the lib can offer `Blackbox.watch(pid)` that
  calls `:sys.log/2` at runtime without touching the GenServer's code.
- **06-35: the `:sys` log leaks what `format_status/1` scrubbed.** A `format_status/1` that scrubs only `:state`
  leaves the secret in the report's `log` entries (the `{:set, "hunter2"}` message and `{:noreply, state}` lines).
  OTP passes `:log` to `format_status/1` too, but authors rarely map it; the lib must scrub the log itself.
- **System snapshot at crash time: pick fields, some are expensive.** Per call (median, 20k loop):

| field | µs |
|---|---|
| `:erlang.memory()` (all) or `memory(:total)` | 47-49 |
| `length(:ets.all())` | 34 |
| `:erlang.statistics(:io)` | 35 |
| `Process.info(self(), :current_stacktrace)` | 10.4 |
| `statistics(:total_run_queue_lengths)` | 0.017 |
| `system_info(:process_count)` | 0.022 |
| `statistics(:reductions)` | 0.074 |
| `Process.info(self(), [:message_queue_len, :memory, :reductions])` | 0.075 |

  A 9-field snapshot is 116 µs and 608 bytes; without `memory`, `ets.all` and `io` it is under 1 µs. So: take the
  sub-µs fields per error; take `:erlang.memory()` at most once per second from a sampler (and keep the last value),
  not per error, or a flood of 10k errors/s spends half a core on `memory/0` alone.
- **`system_monitor` sees mailbox growth and heap blowups**: `long_message_queue` (OTP 26+) fired for a process with
  150 queued messages (06-31); `large_heap` named the process that allocated 500k items (06-33). These are
  "before" signals for a later crash (a GenServer drowning before its call timeouts).
- **But there is one system monitor per node** (06-32): a second `:erlang.system_monitor/2` silently replaces the
  first owner, which then receives nothing. Other tools that set it would fight over it (which ones do: unknown here;
  agent 02 has the field). The lib must read the current owner first and refuse to steal it; OTP 28 fixes this (F).
- **OpenTelemetry**: with only `opentelemetry_api` (no SDK), `current_span_ctx()` is `:undefined` (06-34): nothing to
  record. With an SDK the ids live in the process context (pdict) of the process that crashes, readable from the
  handler like everything else (read, not tested here).
- Reading another process's pdict ring (the Task-crash-to-parent case, 06-10) costs 11 µs with 50 crumbs
  (`Process.info(pid, :dictionary)` copies the whole dictionary): fine per error, not per event.

### Experiment F: OTP 27/28 trace sessions as a per-process flight recorder

Test file `lab/06-before/test/f_trace_test.exs` (+ `lib/recorder.ex`, a tracer GenServer that keeps the last 20
trace messages per pid). First run 4/6; bench `bench/trace.exs` (log `logs/06-bench-trace.log`).

Trace sessions (`:trace.session_create/3`, OTP 27) are isolated: each has its own tracer and its own flags on
processes and functions, so a library can trace without taking the node's single legacy tracer slot.

- A session with the `:receive` flag records the last N messages a process got, and the ring survives the process
  (06-36). **RED 06-36:** the last entry was not `:crash` but `{:code_server, {:module, RuntimeError}}`: receive
  tracing records VM-internal replies too (here, lazy loading of the exception module while dying). A recorder must
  filter those.
- Two sessions and the legacy `:erlang.trace/3` trace the same pid side by side, each gets every event (06-37).
  So the lib coexists with `recon_trace`, `dbg` and observer, which use the legacy slot.
- Call tracing with `return_trace` in a session records the last calls with args and return values (06-38).
- **OTP 28 `:trace.system/3` gives each session its own system monitor** (06-39): two sessions both got
  `long_message_queue` for the same victim. This removes the one-owner problem of `:erlang.system_monitor/2`
  (06-32). On OTP 28+ the lib should use `trace:system/3`; on OTP 26/27 fall back to `system_monitor` only if the
  slot is free.
- Lifetime (06-40 + control 06-40b): the session is destroyed when its last strong handle is garbage collected,
  e.g. when the process that created it exits. Keep the handle in the lib's long-lived recorder process; a dying
  owner cleans up after itself (no leaked tracing). First run of 06-40 was red on a bug in the test itself.
- **The VM never drops trace messages** (06-41): a tracer that does not read got > 50,000 queued messages in 500 ms
  from one call-traced loop. A recorder that traces calls must be bounded by *what* it traces (few pids, few MFAs,
  a match spec) or by a tracer module (`erl_tracer` NIF with its own drop logic, not tested here); a plain process
  tracer is a memory bomb under load. (This test went flaky in the first full-suite run: the worker could finish
  before the flags were set. Fixed with a `:go` handshake; a test race, not a VM fact.)

| (1M local calls / 200k messages, median of 5) | ns |
|---|---|
| local call, untraced | 13.8 |
| local call, function has a pattern, process not traced | 22.6 |
| local call, process call-traced by a session, tracer draining | 285 (+271 ns, ~20x) |
| send to an untraced process | 114 |
| send to a receive-traced process | 106 (no measurable overhead at this resolution) |
| receive loop on a receive-traced process | 21.3 vs 21.1 untraced |

A trace message `{:trace, pid, :receive, msg}` is 64 heap bytes plus the message copy, in the tracer's heap.

Verdict: receive tracing of chosen processes (say, the sidecar, the board servers) is nearly free and gives "the
last 20 messages before the crash" for processes that are not GenServers or did not enable `:sys` logging.
Call tracing is 20x per traced call: only on demand ("record this pid for 60 s") from the UI or an agent,
never always-on.

### Experiment G: a real Plug request on Bandit, with vs without capture

Test file `lab/06-before/test/g_plug_test.exs` (Bandit on port 4361 via `start_supervised!`, Req/Finch client),
plug `lib/lab_plug.ex`. The request does what a typical handler does before an error: 5 `Logger.debug` calls,
3 telemetry "queries", 1 `GenServer.call`. "Full capture" = primary level `:debug` + pdict crumb handler +
telemetry crumbs + a seq_trace label + a reset on `[:bandit, :request, :start]`. Tests 06-42..44 green first run.

- **Bandit runs all keep-alive requests of one connection in one process** (06-42: same pid for consecutive
  requests on one Req connection). A pdict ring or a seq_trace label would leak from request N into N+1. The fix
  is one telemetry handler on `[:bandit, :request, :start]` (runs in the connection process) that clears the ring
  and sets a new label (06-43). (Plug.Cowboy: a process per request; read, not tested here.)
- A crash in the plug is logged in the request process and carries exactly that request's crumbs (06-44).

**Latency, 3 alternating rounds** (`logs/06-plug-latency.log`; the first in-process attempt ran in the test process,
where Plug.Test mails every response to the owner, so its mailbox grew to 40k and slowed each later run: discarded,
fixed with a fresh process per run):

| mode | HTTP p50 (8 clients x 2000) | HTTP p99 | in-process p50 (20k) | in-process p99 |
|---|---|---|---|---|
| off | 173.5 / 237.1 / 218.2 µs | 321 / 473 / 437 µs | 4.8 / 5.2 / 5.2 µs | 17.4 / 25.5 / 31.3 µs |
| full capture | 204.2 / 192.9 / 241.3 µs | 408 / 376 / 484 µs | 10.0 / 9.8 / 10.0 µs | 72.2 / 67.5 / 71.6 µs |

Over HTTP the difference is inside the run-to-run noise (p50 173-237 µs off vs 193-241 µs on). In-process, where
the plug's own work is visible, full capture adds **~5 µs at p50 and ~45 µs at p99** per request.

**Where it goes (06-46, in-process, 3 rounds, middle value):**

| parts on | p50 | p90 | p99 |
|---|---|---|---|
| off | 5.0 µs | 5.8 µs | 25.5 µs |
| primary level `:debug` only (no crumb handler!) | 8.1 µs | 10.3 µs | 66.2 µs |
| + Logger crumb handler | 9.4 µs | 12.9 µs | 72.6 µs |
| telemetry crumbs + seq_trace label only | 5.5 µs | 6.4 µs | 37.3 µs |
| all | 9.8 µs | 13.5 µs | 68.2 µs |

The crumbs themselves are cheap (~1.3 µs for 5 Logger crumbs, ~0.5 µs for 3 telemetry crumbs + label).
**The bill is the primary level.** Switching `:logger` to `:debug` makes every existing `Logger.debug` in the
request build its message and metadata (interpolation, ~1.1 KB garbage each), which moves p50 by +3 µs and p99 by
+40 µs through extra GC. Telemetry-only capture is almost free (+0.5 µs p50; its p99 moved 25 -> 27..39 µs).

### Experiment H: can debug crumbs be sampled per process?

Test file `lab/06-before/test/h_process_level_test.exs`, first run 1/2; bench `bench/process_level.exs`
(log `logs/06-bench-process-level.log`).

- **RED 06-47: `Logger.put_process_level(self(), :debug)` cannot open debug under primary `:info`.** Elixir implements
  the process level as a *primary filter* (`Logger.Utils.process_level/2`, elixir 1.20.4 `lib/logger/utils.ex:91`)
  that can only `:stop` events; the primary level gates before it. The reverse works (primary `:debug`, noisy
  processes muted to `:info`), but a muted process still pays for building the message:

| `Logger.debug("step #{i}", user_id: 42)` | ns |
|---|---|
| primary `:info` | 67 |
| primary `:debug` (console at `:info`) | 814 |
| primary `:debug`, process muted with `put_process_level(:info)` | 507 |

  So "debug crumbs only for sampled requests" is not possible with Logger's levels; the only cheap selectors are
  per-module levels (06-5: `Logger.put_module_level/2`, checked in the macro via `:logger.allow/2`).
- ETS ring rows outlive their process (06-48, green): an ETS ring needs a monitor or a sweeper.


### Experiment I: joining a crash to its request's trail (claims relayed from report 02)

Test file `lab/06-before/test/i_join_test.exs`, all 5 green first run. The `Joiner` handler (in the test file)
runs inline in the crashed process and gathers: its own ring, the rings of its `$callers`, the ring of the
`client_info` pid, and the seq_trace label.

- **Backend-style handlers lose the pdict ring** (06-49): a handler that hands the event to another process (the
  gen_event / old Logger backend shape) reads an empty ring there. Crumbs carried *in the event's metadata*
  (Sentry's approach: breadcrumbs in Logger metadata) survive the hop. So: read the ring inline in `log/2`,
  copy it into the event, then hand off. Same for raw `spawn` crashes (06-11), where no handler runs in the dead process.
- **`Task.Supervisor.async_nolink` crash:** `$callers` joins the task's own crumbs `[:task_step]` to the request's
  `[:request_step_1]` (06-50), read with `Process.info(parent, :dictionary)` from the task's handler.
- **`GenServer.call` into a long-lived server:** `$callers` is empty and `$ancestors` is the supervisor, but the
  terminate report's `client_info` pid is the request process, *still alive and blocked in the call* while the
  server's handler runs, so its ring is readable (06-51). This is the answer for long-lived servers.
- **`GenServer.cast` (or `send`) into a long-lived server:** no `client_info`, no `$callers`; only the seq_trace label
  names the request (06-52). Logger metadata does not travel with messages (06-15); passing it along means the app
  wraps every message, which nobody does, so the label is the only zero-code join.
- **Fire-and-forget work that outlives its request** (`Task.Supervisor.start_child`, the request already
  finished): `$callers` points at a dead pid and the trail is gone (06-53). Only the label (inherited at spawn,
  06-25) still names the request. To show the request's crumbs in that case, the lib has to store the request's trail
  when the request ends (e.g. keep the last N finished request trails in a bounded ETS table keyed by label for a few
  seconds). Not measured here.

## Claims table

All in `lab/06-before/test/`. Final suite: `mix test` -> **52 passed, 2 excluded (bench)**, seeds 863259, 736442,
563600 (3 runs, deterministic after fixing one test race, see 06-41). First-run column is the honest first outcome.

| id | claim (as first written) | first run | final truth | test file |
|---|---|---|---|---|
| 06-1 | primary `:info` drops `Logger.debug` before any handler, even one at `:all` | green | same | a_logger |
| 06-2 | primary `:debug`, console at `:info`, crumb handler at `:all`: only the crumb handler sees debug | green | same | a_logger |
| 06-3 | a `:logger` handler runs in the process that called Logger | green | same | a_logger |
| 06-4 | disabled `Logger.debug` does not evaluate its arguments | green | same | a_logger |
| 06-5 | a module level opens debug for one module under primary `:info` | green | same | a_logger |
| 06-6 | a crumb handler fills the caller's own pdict ring, per process | green | same | a_logger |
| 06-7 | the pdict ring keeps the newest 50 | green | same | a_logger |
| 06-8 | a GenServer crash is logged from the dying process; the handler reads its pdict ring | green | same | b_crash_context |
| 06-9 | the proc_lib crash report (with the dictionary) reaches a handler at `:all` | **red** | Elixir's primary `logger_translator` filter (`sasl: false`) drops it for all handlers; with `sasl: true` it arrives with the dictionary | b_crash_context |
| 06-10 | a Task crash runs the handler in the task; `$callers` names the parent, whose ring is readable | green | same | b_crash_context |
| 06-11 | a raw `spawn` crash is logged outside the dead process; its pdict is gone | green | same | b_crash_context |
| 06-12 | a crash in `call` reports `last_message = {:"$gen_call", from, msg}`, state, client pid | **red** | `last_message` is the bare request; the caller is `client_info = {pid, {pid, stacktrace}}` | b_crash_context |
| 06-13 | a crash in `cast`: `last_message = {:"$gen_cast", msg}`, `client_info: :undefined` | green | same | b_crash_context |
| 06-14 | `format_status/1` scrubs `state` in the report | green | same | b_crash_context |
| 06-15 | Logger metadata is not inherited by a Task, `$callers` is | green | same | b_crash_context |
| 06-16 | Logger metadata set inside a GenServer rides on its crash event | green | same | b_crash_context |
| 06-17 | `$ancestors` name the starter, not the caller | green | same | b_crash_context |
| 06-18 | a telemetry handler runs in the emitting process | green | same | c_telemetry |
| 06-19 | a raising telemetry handler is detached; `[:telemetry, :handler, :failure]` fires | green | same | c_telemetry |
| 06-20 | no prefix/wildcard attach | green | same | c_telemetry |
| 06-21 | `list_handlers([])` reveals attached event names | green | same | c_telemetry |
| 06-22 | a seq_trace label (any term) travels with `GenServer.call` | green | same | d_seq_trace |
| 06-23 | a later untokened message clears the label (no leak to the next caller) | **red** (confounded) | true; the first run's "clean" caller was a Task that had inherited the label (06-25) | d_seq_trace |
| 06-24 | cast and plain send carry the label | green | same | d_seq_trace |
| 06-25 | a spawned Task does not inherit the label | **red** | spawned processes (Task and raw `spawn`) DO inherit it | d_seq_trace |
| 06-26 | the crash handler of a GenServer that crashed in a labelled call reads the label | green | same | d_seq_trace |
| 06-27 | the reply brings the label back and it stays set in the caller | green | same | d_seq_trace |
| 06-28 | `debug: [log: 10]` ships the last 10 events in the terminate report | green | same | e_sys |
| 06-29 | `:sys.log/2` turns it on at runtime | green | same | e_sys |
| 06-30 | without it the report's `log` is `[]` | green | same | e_sys |
| 06-31 | `system_monitor` `long_message_queue` fires (OTP 26+) | green | same | e_sys |
| 06-32 | one system monitor per node: a second owner silently replaces the first | green | same | e_sys |
| 06-33 | `system_monitor` `large_heap` names the process | green | same | e_sys |
| 06-34 | OTel API without SDK: `current_span_ctx() == :undefined` | green | same | e_sys |
| 06-35 | scrubbing only `:state` in `format_status/1` leaves secrets in the `:sys` log entries | green | same | e2_sys_scrub |
| 06-36 | a receive-tracing session records the last N messages; the last is the one that crashed it | **red** | receive tracing also records VM-internal replies (code server loading the exception module) | f_trace |
| 06-37 | two sessions + legacy trace coexist on one pid | green | same | f_trace |
| 06-38 | call tracing in a session records args and return values | green | same | f_trace |
| 06-39 | OTP 28 `trace:system/3`: per-session system monitors, both notified | green | same | f_trace |
| 06-40 | a session dies with its last strong handle | **red** (test bug) | true after fixing the helper; control 06-40b green | f_trace |
| 06-41 | the VM never drops trace messages: a non-reading tracer queues > 50k in 500 ms | green (then flaky: test race, fixed) | same | f_trace |
| 06-42 | Bandit runs keep-alive requests of one connection in one process | green | same | g_plug |
| 06-43 | a reset on `[:bandit, :request, :start]` gives each request a clean ring and new label | green | same | g_plug |
| 06-44 | a plug crash is logged in the request process with that request's crumbs only | green | same | g_plug |
| 06-45 | latency with vs without full capture (bench) | n/a | +5 µs p50, +45 µs p99 in-process; invisible over HTTP | g_plug |
| 06-46 | cost decomposition (bench) | n/a | primary `:debug` is the bill; crumbs ~1.8 µs | g_plug |
| 06-47 | `put_process_level(:debug)` opens debug for one process under primary `:info` | **red** | impossible: the process level is a primary filter that can only drop | h_process_level |
| 06-48 | ETS ring rows outlive their process | green | same | h_process_level |
| 06-49 | a backend-style handler (work in another process) sees no pdict ring; crumbs in event metadata survive | green | same | i_join |
| 06-50 | `Task.Supervisor.async_nolink` crash joins the request ring via `$callers` | green | same | i_join |
| 06-51 | `call` into a long-lived server: `$callers` useless, `client_info` pid (blocked caller) gives its ring | green | same | i_join |
| 06-52 | `cast` into a long-lived server: only the seq_trace label joins it | green | same | i_join |
| 06-53 | fire-and-forget task after the request finished: `$callers` pid dead, trail lost | green | same | i_join |

Tally: 52 tests, 7 red on first run (06-9, 06-12, 06-23, 06-25, 06-36, 06-40, 06-47); of those, 2 were bugs in the
test (06-23 confounded, 06-40 helper crash) and 5 were wrong beliefs about the BEAM or Elixir.

## Findings table

| id | what | evidence | priority | proposal | size |
|---|---|---|---|---|---|
| F1 | proc_lib crash handlers run in the dying process: its pdict ring is readable at crash time for free | 06-8, 06-10 | P0 | per-process pdict ring as the default crumb store | S |
| F2 | Elixir drops the proc_lib crash report (dictionary, links, queue) for every handler by default | 06-9 | P0 | don't rely on it; read pdict/`Process.info` in the handler; document `handle_sasl_reports` | S |
| F3 | GenServer call crashes name the caller and its stack (`client_info`); casts don't | 06-12, 06-13 | P0 | link a GenServer crash to the request by `client_info` pid -> that pid's ring/label | S |
| F4 | seq_trace label = zero-code request id across call/cast/send/spawn, +128 ns per call | 06-22..27 | P1 | set a small label per request/job; read it in every crash handler | S |
| F5 | spawned processes inherit the label; long-lived processes started in a request carry it until their next untokened message | 06-25 | P1 | clear label in the lib's own long-lived processes' `init`; document | S |
| F6 | Bandit reuses the connection process across keep-alive requests | 06-42 | P0 | reset ring + label on `[:bandit, :request, :start]` (and Cowboy/Phoenix equivalents) | S |
| F7 | primary level `:debug` is the dominant cost of Logger crumbs (+3 µs p50, +40 µs p99 per request with 5 debug calls) | 06-46, bench | P0 | Logger crumbs opt-in; default crumbs from telemetry + `:info`+ logs | S |
| F8 | per-process debug sampling via `put_process_level` is impossible | 06-47 | P2 | offer per-module debug (`put_module_level`) for chosen modules instead | S |
| F9 | a single GenServer ring drowns (8.5M queued msgs in 3 s) | bench logger | P0 | never route crumbs through one process | S |
| F10 | ETS ring leaks rows of dead pids (59 MB in one bench) | 06-48, bench | P1 | ETS only for raw-spawn processes, with a monitor or periodic sweep | M |
| F11 | `:sys` debug log gives the last N messages/replies/states of a GenServer for +56 ns per call | 06-28..30 | P1 | `Blackbox.watch(pid, n)` = `:sys.log/2` at runtime; show in timeline | S |
| F12 | `format_status` authors rarely scrub `log`; secrets leak through the `:sys` log | 06-35 | P0 | lib scrubs log entries with the same scrubber as state/params | S |
| F13 | one legacy system monitor per node; OTP 28 `trace:system/3` gives per-session monitors | 06-32, 06-39 | P1 | OTP 28: session monitor (long_message_queue, long_gc, large_heap); older: only if free | M |
| F14 | trace sessions coexist with dbg/recon; receive tracing ~free; call tracing +271 ns per call; tracer queue unbounded | 06-36..41, bench | P2 | "record this pid for 60 s" on demand from the UI/agent API, receive-only by default, bounded by time | M |
| F15 | `:erlang.memory()`, `ets.all`, `statistics(:io)` cost 35-49 µs each; the useful others are < 0.1 µs | bench snapshot | P1 | per-error snapshot of sub-µs fields; memory sampled once a second | S |
| F16 | telemetry handlers get detached on the first raise | 06-19 | P0 | watch `[:telemetry, :handler, :failure]` for own ids; re-attach, count, report | S |
| F17 | reading another process's pdict costs 11 µs (50 crumbs) | bench sys | P2 | fine per error (Task -> `$callers` parent), never per event | S |
| F18 | receive tracing records VM-internal replies | 06-36 | P2 | filter `{:code_server, _}` and `{ref, _}` replies from recorder output | S |
| F19 | the join order that works: own ring -> `$callers` rings -> `client_info` ring -> seq_trace label; backends that hop processes see none of it; work outliving its request loses the trail | 06-49..53 | P0 | build the "before" section inline in the handler; keep finished request trails briefly by label | M |

## Recommendations for the lib

1. **Crumb store = the process dictionary of the process doing the work**, a bounded ring (`{count, list}`,
   50 entries, trim at 100; 42 ns per add, 4.4 KB full). The crash handler runs in the dying process for every
   proc_lib process (GenServer, Task, Agent, gen_statem, Bandit connection), so it reads the ring with
   `Process.get/1`, no shared state, no messages, freed by the VM (F1, F9, F10).
2. **Link crashes to their cause, cheapest first:** (a) handler in the crashed process reads its own ring and
   seq_trace label; (b) Task: `$callers` -> `Process.info(parent, :dictionary)` if alive (11 µs); (c) GenServer crash
   inside a call: `client_info` pid -> that pid's ring/label; (d) cast/send/spawn: the seq_trace label (F3, F4).
   Gather all of this inline in the handler's `log/2` and copy it into the event before any hand-off to a
   writer process; a backend in another process sees none of it (06-49..53, F19).
3. **Request id via `:seq_trace.set_token(:label, id)`** set on `[:bandit, :request, :start]`,
   `[:phoenix, :endpoint, :start]`, Oban job start; tiny label (an integer or short binary, never a map), cleared
   at request stop and in the lib's own processes. Opt-out switch for nodes that use seq_trace for real (F4, F5, F6).
4. **Reset per request** on the server's start event (Bandit keeps one process per connection): clear the ring and
   set a new label (F6).
5. **Default crumb sources (always on, ~0.1-0.3 µs each):** telemetry events of known libs (Phoenix, Plug,
   Bandit, Ecto repo from config, Finch/Req, Oban, LiveView, Absinthe) with measurements and a few whitelisted
   scrubbed metadata fields; Logger events at the app's existing level (`:info`+) through a handler at level `:all`.
6. **Logger debug crumbs are opt-in**, with the measured price in the docs: primary `:debug` costs ~0.8 µs per
   existing debug call site, +40 µs p99 per request in our lab. Offer `debug_crumbs: [modules: [...]]` via
   `Logger.put_module_level/2` instead of a global switch (F7, F8). Set every other handler's level to the old
   primary level when turning it on.
7. **GenServer flight recorder on demand:** `Blackbox.watch(pid_or_name, n \\ 10)` calls `:sys.log(pid, {true, n})`
   (+56 ns per call); the `{:gen_server, :terminate}` report's `log` becomes the "last N messages" section. Scrub
   `log`, `state`, `last_message` with the lib's scrubber after `format_status/1` (F11, F12).
8. **Per-error snapshot, fixed field list, sub-µs:** run queue, process count, the crashed process's
   `message_queue_len`, `memory`, `reductions`, `links`; the crash's own stack is already in the report. Keep
   `:erlang.memory()` (47 µs) from a 1 s sampler, and never call `ets.all`/`statistics(:io)` per error (F15).
9. **"Before" health signals:** on OTP 28 open a trace session and use `trace:system/3` for `long_message_queue`,
   `long_gc`, `large_heap`, `long_schedule` into a node-level ring (the last 50 system events shown on every
   error's timeline). On OTP 26/27 use `:erlang.system_monitor/2` only if `system_monitor()` returns `:undefined`,
   and say so on the health page (F13).
10. **On-demand process recording**, not always-on: "record pid X for 60 s" (receive tracing, near-free; call tracing
    only with an MFA filter, +271 ns per call) through a trace session owned by the lib's recorder process, with a
    hard time and count limit, since trace messages are never dropped (F14, F18).
11. **Guard the lib's own handlers:** telemetry detaches a raising handler for good, OTP removes a raising logger
    handler; watch `[:telemetry, :handler, :failure]` and the logger handler list, re-attach with backoff, and
    report the fault as a lib-internal event (F16).
12. **Don't depend on `handle_sasl_reports`** (F2): everything the proc_lib crash report adds (dictionary, links,
    queue length) the handler can read itself from the dying process.
13. **OTel:** read trace/span ids from the crashing process's context when an SDK is present; record nothing
    otherwise (06-34).

## Sources

- Lab (verified): `docs/research/0031-errors/lab/06-before/` (tests `test/*.exs`, benches `bench/*.exs`,
  ring buffers `lib/ring.ex`, handlers `lib/handlers.ex`, trace recorder `lib/recorder.ex`, plug `lib/lab_plug.ex`).
- Logs (verified): `logs/06-tests.log` (first outcomes, seeds, final summary lines), `logs/06-bench-logger.log`,
  `logs/06-bench-telemetry.log`, `logs/06-bench-seq_trace.log`, `logs/06-bench-sys.log`,
  `logs/06-bench-snapshot-fields.log`, `logs/06-bench-trace.log`, `logs/06-plug-latency.log`,
  `logs/06-bench-process-level.log`.
- OTP 28 source (read): `kernel-10.6.3.4/src/trace.erl` (session_create doc: "If the handle is dropped and garbage
  collected, the session will be destroyed"; `system/3` "since OTP 28.0", per-session system monitor).
- Elixir 1.20.4 source (read): `lib/logger/lib/logger/utils.ex:91` (`process_level/2` primary filter);
  `lib/logger/lib/logger.ex:884` (`put_process_level/2` stores the level in the pdict).
- Versions: Elixir 1.20.4, Erlang/OTP 28 (erts 16.4.0.6), bandit, plug, req 0.7.4, telemetry, benchee 1.5.1,
  opentelemetry_api (as resolved in `lab/06-before/mix.lock`).
- Machine: Apple M3 Pro, 11 cores (`sysctl -n machdep.cpu.brand_string`).
