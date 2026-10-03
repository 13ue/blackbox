# 04 BEAM failure surface lab

Agent 04, 2026-09-27. Elixir 1.20.4 / OTP 28 (erts 16.4.0.6), Apple M3 Pro.
Lab: `docs/research/0031-errors/lab/04-beam/` (mix project, no deps).
Logs: `logs/04-*.log`. Everything below marked **verified** was run as an ExUnit test
in that lab; **read** means OTP/Elixir source or docs.

## Summary for the lead

1. **No single hook sees everything, and Elixir's defaults hide the supervision layer.** Elixir 1.20 installs a *primary* `logger_translator` filter that `:stop`s every `[:otp, :sasl]` report unless `handle_sasl_reports: true`: GenServer `init` crashes, supervisor restarts, max-intensity give-ups and brutal kills produce **zero** handler events by default (04-15, 04-27..29). The lib must flip that filter (or ask users to set the config) and dedupe the 2-4 events one crash then yields, by `meta.pid` (04-27s, 04-39).
2. **Only raise/throw/error in plain processes and OTP-behaviour deaths are logged.** `exit(:boom)`, `exit(:kill)`, `Process.exit(pid, :kill)`, death by link, `{:shutdown, _}` and call/await timeouts leave nothing (04-3, 04-8, 04-11, 04-12, 04-20, 04-23). Covering them needs monitors or a trace session on `:procs`, not logger.
3. **Event shapes differ per source; normalize four of them**: emulator `{:string, _}` + `crash_reason`, no domain/mfa, runs in `:logger_proxy` (04-1); gen_server flat report with `last_message`, `state`, `client_info` incl. the caller's live stacktrace (04-17); gen_statem `{class, reason, stack}` + `queue` (04-26); Task report with `callers`, `starter`, `process_label` (04-6). Elixir's translator adds `crash_reason` to all of them; meta `mfa` points at OTP internals.
4. **Stacks are often missing or short**: throw inside a GenServer callback becomes `{:bad_return_value, v}` with `[]` stack (04-19); `{:stop, r}` has no stack (04-21); `backtrace_depth` is 8 in production (ExUnit silently sets 20), and self-recursion collapses to one frame (04-34). Set depth to 32-64 at start; fingerprint must work without frames.
5. **Free "before" data OTP already carries**: `:sys` debug `log` (last N in/out events + state) in gen_server reports when started with `debug: [log: n]` (04-35); the full mailbox, dictionary, links, `$callers`/`$ancestors` in proc_lib crash reports once SASL is on (04-16); the dying process's `Logger.metadata` (Task/GenServer yes, plain spawn no, 04-36); `process_label` (04-32/33, not in plain spawn 04-31).
6. **Silent failures (rescued, `{:error, _}`, `catch :exit`) reach no handler (04-40); OTP 27+ `:trace` sessions can see most of them and are isolated per session (04-48).** Call-tracing `erlang:error/1,2,3` + `throw/1` costs ~0 on the happy path and +0.35 µs + one message per raise (04-51/52); it misses VM-instruction errors (badmatch, badarith, case_clause, 04-45) and binds only to loaded modules (04-49). `exception_trace` is ~5,000x per call and slows *every* process ~4.5x once a pattern exists (04-51): never always-on.
7. **Handlers run in the logging process** (caller, dying process, or `:logger_proxy`): a 20 ms handler adds 20 ms to `Logger.error` (04-63). `log/2` must only enqueue.
8. **A crashing handler is removed silently for an `:error`-level tracker**: OTP removes it and tells other handlers only at `:debug` (04-60). **There is no recursion guard**: a handler that logs re-enters itself (04-64). The lib needs `try` around `log/2`, a re-entrancy flag, and a watchdog that re-adds itself.
9. **Under a flood the VM itself drops crash reports**: 10k crashing `spawn`s → 1,665-4,799 delivered; `:logger_proxy` enters drop mode by unsetting `system_logger`, the only trace is an uncounted `:notice` (04-68). `logger_std_h` writes 500 of 10,000 (burst limit, 04-66/67). The `:logger` core itself drops nothing (10k/10k in 11-22 ms, 04-65). Record drop-mode notices as "lost: unknown" and raise `logger_proxy` limits if the lib wants counts.
10. **Applications dying are `:notice`, not `:error`** (04-37/38): attach at `:notice` for `{:application_controller, :exit}` or miss app crashes. Suite: 72 tests, 51 green / 20 red on first run (+1 flaky, reworded), 3 x green (seeds 806046, 206179, 370822), `lab/04-beam/`. Least invasive way to get SASL reports: our own primary filter, which runs before the translator (E6).

## Method

- One test `:logger` handler (`BeamLab.Capture`) added per test with `:logger.add_handler/3`
  (level `:all`), removed in `on_exit`. Its `log/2` sends `{:log_event, event, self()}` to the
  test pid, so every test asserts the exact `level`, `meta.domain`, `msg` shape (`{:report, map}`
  vs `{:string, _}` vs `{format, args}`), and metadata keys (`crash_reason`, `mfa`, `pid`,
  `error_logger`, `$callers`, ...). The handler also reports `self()` = the process the handler runs in.
- Tests written with the expected assertion first, run once, first outcome recorded (red/green),
  then red assertions changed to the observed truth. Suite run 3 times for flakiness.
- Elixir's default `:logger` handler stays attached (it prints to console, no effect on assertions);
  `handle_otp_reports`/`handle_sasl_reports` defaults as shipped with Elixir 1.20 unless a test says otherwise.

## Experiments (appended as they run)

### E1. Plain processes and Tasks (tests 04-1 .. 04-14, `test/a_processes_test.exs`) — verified

First run: 11 green, 3 red (04-1, 04-2, 04-10). Facts after the run:

- **Primary filters decide before any handler.** Elixir 1.20 installs two *primary* filters:
  `logger_translator` (`&Logger.Utils.translator/2`, config `%{otp: true, sasl: false, ...}`) and
  `logger_process_level`. The translator returns `:stop` for domain `[:otp, :sasl | _]` and
  `[:supervisor_report | _]` when `handle_sasl_reports` is false (the default), so **no handler, ours
  included, ever sees supervisor/crash/progress reports by default** (read: `logger/lib/logger/utils.ex:11-13`,
  Elixir 1.20.4; primary config printed in `logs/04-lab.log`). It also *rewrites* every OTP report it
  understands: adds `meta.crash_reason` (+ `callers`, `ancestors`, registered name, the dying process's
  `Logger.metadata`) and puts the English text under `report.elixir_translation`.
- **Plain `spawn` crashes** (raise, throw, BIF badarg, `:erlang.error`): one `:error` event emitted by
  the emulator, delivered via the **`:logger_proxy`** process (so the handler runs there, not in the
  crashed process, not in `:logger`). Meta: `pid` (the dead one), `gl`, `time`,
  `error_logger: %{tag: :error, emulator: true}`, `crash_reason`. **No `domain`, no `mfa`, no file/line.**
  After translation `msg` is `{:string, chardata}`: the original `{format, [pid, {reason, stack}]}`
  is gone, the structured data survives only in `crash_reason`.
- A `throw` in a plain process arrives as `{%ErlangError{original: {:nocatch, :boom}}, stack}`: the
  kind `:throw` is lost.
- **`exit(:boom)` in a plain process logs nothing.** Neither does `exit(:kill)`,
  `Process.exit(pid, :kill)`, or a process dying from a link signal. Only raise/throw/error in a
  plain process reach logger.
- **Tasks log their own**: `{Task.Supervisor, :terminating}` report at `:error`, domain `[:otp, :elixir]`,
  handler runs **in the dying task process**, meta `callers` (the `$callers` chain) + `crash_reason`;
  report keys `args, function, name, reason, process_label, starter`. Tasks log non-normal exits too
  (`exit(:boom)`), not `:normal` / `{:shutdown, _}`. No `ancestors`, no `mfa` in meta.
- Callers of a crashed `Task.async` die by the link silently; `Task.await` timeouts kill the caller
  with `{:timeout, {Task, :await, _}}` and nothing is logged unless the caller is itself a
  GenServer/Task that logs its own death.

### E2. OTP behaviours, supervisors, SASL (tests 04-15 .. 04-30, 04-16/27s/28s/29s, `test/b_otp_test.exs`) — verified

First real run: 16 green, 3 red (04-17 report shape, 04-19 throw semantics, 04-26 shape; the first
invocation crashed on a harness bug, `Srv.start_link/1` missing, and is not counted).

- **`{:gen_server, :terminate}` report is flat**: `%{label, name, reason, log, state, last_message,
  process_label, client_info}` + `elixir_translation`. Domain `[:otp]`, level `:error`, logged **in the
  crashing server** (handler `self()` = server pid). `client_info` for a `call` is
  `{client_pid, {client_pid, client_current_stacktrace}}`: OTP samples the **caller's stack at crash
  time** (local callers only) — a free "who asked" for the event. Meta `mfa/file/line` point at
  `:gen_server` internals, useless for grouping. Meta has `crash_reason` but **no `callers`/`ancestors`**.
- `:gen_statem` differs: reason is a 3-tuple `{class, reason, stack}`, it has `queue` (pending events
  incl. the one being handled), `modules`, `state = {state_name, data}`, **no `last_message`**. A
  normalizer needs one clause per behaviour.
- **`throw` inside a GenServer callback is a return value**: reason `{:bad_return_value, :boom}`,
  stacktrace `[]`. `{:stop, :boom, s}` also yields `crash_reason {:boom, []}` — no stack. Grouping
  must not assume a stacktrace.
- `terminate/2` raising replaces the original reason (the first crash is gone from the report).
- `GenServer.call` timeouts are caller-side only; nothing is logged unless the caller then dies in a
  process that logs its own death.
- `use GenServer` without `handle_info` logs `{GenServer, :no_handle_info}` at `:error` and keeps running.
- **Default Elixir config hides the supervision layer entirely.** `init` crashes (04-15), supervisor
  restarts (`child_terminated`), max-intensity give-ups (`{:supervisor, :shutdown}`; the supervisor
  itself exits `:shutdown`, which gen_server does not log) and brutal kills (`:killed`) produce **zero
  events** unless the `logger_translator` primary filter lets `[:otp, :sasl]` through
  (`config :logger, handle_sasl_reports: true`, or what `BeamLab.Sasl.set(true)` does at runtime:
  replace the primary filter with `sasl: true`). A brutal kill of a supervised child is visible
  *only* as `child_terminated` with `reason: :killed`; an unsupervised killed process leaves nothing.
- With SASL on, one child crash produces **4 events** (gen_server terminate, proc_lib crash report,
  supervisor child_terminated, supervisor progress for the restart): dedupe by `pid`.
  The proc_lib crash report is the richest snapshot OTP gives for free: `messages` (the mailbox),
  `message_queue_len`, `links`, `dictionary` (incl. `$callers`, `$ancestors`, `$logger_metadata$`),
  `trap_exit`, `heap_size`, `reductions`, `error_info`, `neighbours` (linked procs).

### E3. Labels, stack depth, `:sys` log, metadata, applications (tests 04-31 .. 04-38, `test/c_details_test.exs`) — verified

First run: 5 green, 3 red (04-34, 04-37, 04-38); a second red on 04-34 after the first fix.

- **Process labels (OTP 27 `Process.set_label/1`)** show up as `process_label` in Task, gen_server and
  gen_statem reports and in proc_lib crash reports, **not** in plain-spawn emulator events (label
  `:plain_x` nowhere in the event). To label plain processes the lib must read `Process.info(pid, :label)`
  itself — impossible after death, so only via its own wrapper or a trace session.
- **`backtrace_depth`**: 8 in a plain `erl`/`elixir` VM, but **ExUnit sets 20** (`ex_unit/runner.ex:45`),
  so tests lie about production stack depth. At 8, a 20-deep mutual recursion is cut to 8 frames;
  at 64 it keeps ≥21. Also: **self-recursion through one call site is collapsed** — `down(20)` yields
  only 2 frames (`down/1` raise site + one `down/1` caller frame). Recommendation: set
  `:erlang.system_flag(:backtrace_depth, 32..64)` at lib start (global, cheap: only stacks that are
  captured pay).
- **`:sys` debug log** (`GenServer.start(M, a, debug: [log: 5])`) lands in the report's `log` key:
  `{:in, msg}`, `{:out, reply, to, new_state}` ... ending with the crashing message. This is OTP's
  built-in "what happened before" for one process, off by default (full `log` of dozens of servers
  costs memory per event; agent 06 measures). Sample in `logs/04-sys-log.txt`.
- **Logger metadata of the dying process** (`Logger.metadata(request_id: ...)`) is in the event for
  Task and gen_server reports (they log from the dying process, and `:logger` merges process metadata),
  **absent for plain spawn** (logged from `:logger_proxy`). So request correlation via metadata works
  for OTP processes and fails for bare `spawn`.
- **Applications**: `Application.stop` and a temporary application dying because its top supervisor
  was killed both produce exactly one `{:application_controller, :exit}` report at **`:notice`**
  (`exited: :killed, type: :temporary`). A handler at level `:error` never sees an application
  dying. (A permanent app takes the node down; then only the next boot's `erl_crash.dump` or
  `init:stop` remains, agent 07.)

### E4. The silent failures and OTP 27+ trace sessions (tests 04-40 .. 04-53, `test/d_trace_test.exs`, `test/e_trace_cost_test.exs`) — verified

First run: 04-40, 44, 46, 48, 49 green; 04-43, 45, 47, 50, 51, 52 red (details in the claims table).
Numbers in `logs/04-cost.log` (Apple M3 Pro, OTP 28, JIT, 11 schedulers).

- **Rescued-and-swallowed exceptions, `{:error, _}` returns and `catch :exit` reach no logger handler.**
  The only BEAM mechanism that sees them without code changes is tracing.
- **`:trace` sessions (OTP 27+)** — `:trace.session_create(name, tracer, [])`, `:trace.function/4`,
  `:trace.process/4`, `:trace.session_destroy/1` — are isolated: two sessions trace one process
  independently and destroying one does not disturb the other (04-48). The lib can own a session
  without fighting `:dbg`, `recon_trace` or a developer's session (before OTP 27 a process had one tracer).
- **What each pattern sees**:
  - `exception_trace` on a module: sees an exception leaving a function (`:exception_from`) even when a
    caller rescues it. Does **not** see raise+rescue inside one function (04-44).
  - call trace on `{:erlang, :error | :exit | :throw, :_}`: sees every *explicit* raise/throw/exit call,
    including those rescued in the same function and BIF errors that OTP raises through Erlang-level
    wrappers (`atom_to_binary/1` calls `erlang:error/3`). It does **not** see errors raised by VM
    instructions: `badarith`, `badmatch`, `case_clause`, `element/2` badarg (04-45). Exits are noisy:
    a `GenServer.call` to a dead pid calls `exit/1` twice (04-47).
  - `return_trace` shows `{:error, _}` returns, but the match spec runs at call time, so every return
    is sent and the tracer must filter (04-46).
  - Patterns only bind to **loaded** modules; a module loaded later stays untraced (04-49). In
    interactive mode (dev, `mix test`) modules load lazily, so a wildcard set at boot misses code.
    Releases (embedded mode) preload everything.
  - `silent` mode cannot keep only exceptions: it suppresses `exception_from` too (04-50).
- **Costs** (median of 3, ns per loop iteration of two tiny local calls):

  | setup | ns/iter | vs baseline | messages |
  |---|---:|---:|---:|
  | no pattern | 2.6-3.1 | 1x | 0 |
  | `{Silent,_,_}` exception_trace, this process NOT traced | 13.6-14.8 | ~4.5x for **every** process calling those functions | 0 |
  | same, this process traced | ~16,000 | ~5,000x | 4 per iteration |
  | `{_,_,_}` on all 23,590 loaded functions, NOT traced | 13.9-14.8 | ~4.5x everywhere | 0 |
  | `{:erlang, :error/:exit/:throw, _}` call trace, traced | 2.6-3.4 | ~1x (noise) | 0 |
  | 100k swallowed raises, no trace | 58-70 ns/raise | | |
  | 100k swallowed raises, `erlang:error` traced | 410-430 ns/raise | +0.35 µs/raise | 1 per raise |

  Setting `{_,_,_}` takes 6-8 ms here (23,590 functions); a real release has several times more.
  **Verdict:** `exception_trace` is a debugging tool, never always-on. A call trace on
  `erlang:error/1,2,3` + `erlang:throw/1` (+ maybe `exit/1`) with `:trace.process(s, :all, true, [:call])`
  is cheap enough for an **opt-in "swallowed exceptions" sampler**: zero cost on the happy path,
  ~0.35 µs + one message per raise. It needs a tracer process with its own overload protection (a
  raise flood becomes a message flood) and it misses instruction-raised errors. Not measured: the
  `:all` process flag across many schedulers under real load.
- Found by accident (04-53): **a raise costs O(stack depth)** — 0.07 µs in a tail loop, 48 µs inside a
  100k-deep body recursion (`for`/`Enum.map`). Cause unknown (not researched). Matters for any
  benchmark of the lib's own `try` wrappers.

### E5. Handler safety and floods (tests 04-60 .. 04-69, `test/f_handler_safety_test.exs`) — verified

First run: 04-63, 65, 66, 67 green; 04-60, 64, 68 red; 04-69 red in 1 of 3 runs (reworded, now asserts
only the stable part). Raw numbers in `logs/04-flood.log`.

- **Where a handler runs** (proven by the handler sending `self()`):
  `Logger.error`/`:logger.*` calls → the **calling process** (04-13; a 20 ms handler makes the call
  take ≥20 ms, 04-63); gen_server/gen_statem/Task reports → the **dying process** during its
  termination; plain-process crash reports from the emulator → **`:logger_proxy`**. The lib's
  `log/2` must therefore be O(1) and non-blocking: enqueue into an ETS table or a bounded buffer
  process, never do I/O, never call into a GenServer synchronously.
- **A failing handler is removed** (raise, exit and throw all; `logger_backend.erl:55-67`, kernel
  10.6.3.4). The caller never sees it; other handlers still receive the event, and additionally get
  a **`:debug`** report `[logger: :removed_failing_handler, handler: {id, mod}, log_event, config,
  reason: {class, reason, stack}]` with `internal_log_event: true`. A tracker filtered at `:error`
  would not notice its own removal: the lib must wrap its `log/2` in `try` itself (never crash) and
  still have a watchdog that re-adds the handler if `:logger.get_handler_ids()` loses it.
- **No recursion guard in OTP** (04-64): a handler that logs from `log/2` re-enters itself
  synchronously — stopped only by our cap at depth 1000. An error while reporting an error loops.
  The lib needs a process-dictionary re-entrancy flag (and must never call `Logger` from its own
  pipeline without it).
- **The logger core does not drop** (04-65): 10,000 `Logger.error` from 100 processes reached a sync
  handler 10,000 times in 11-22 ms. Elixir's `discard_threshold` (500) applies only to
  `Logger.Backends`, not to `:logger` handlers. Overload protection is each handler's job.
- **`logger_std_h` (the default console/file handler) protects itself hard**: its default
  `burst_limit_max_count 500` per `burst_limit_window_time 1000 ms` wrote **500 of 10,000** events in
  the flood and **500 of 2,000** from one process (04-66/67); drop/flush notices appear only
  sometimes. What the console shows during an incident is a sample.
- **Crash reports from plain processes are dropped by the VM under load** (04-68): 10,000 crashing
  `spawn`s → only **1,665-4,799** reached the handler. `:logger_proxy` (defaults `sync_mode_qlen
  500, drop_mode_qlen 1000, flush_qlen 5000, burst_limit_enable false`, `logger_proxy.erl:104-109`)
  switches to drop mode by setting `erlang:system_flag(system_logger, undefined)` (`:154-160`), and the
  emulator then discards its error reports. The only trace is two `:notice` events ("logger_proxy
  switched from async to drop mode" / back), **with no count**. Tunable via
  `:logger.set_proxy_config/1`. With a slow (1 ms) handler the proxy queue overshoots its 1000 limit to
  1,364-4,951 before drop mode reacts (04-69).
- Consequence for dedupe/"count everything": the lib cannot rely on seeing every occurrence during
  a flood; it should count what it sees, record `logger_proxy` drop-mode notices as "N unknown lost"
  markers, and use its own `:counters` for occurrences of already-known fingerprints.

## Claims table

62 tests; first run: 43 green (one written after the observation, 04-53; one green once a shape fix from a sibling test was applied, 04-26), 18 red (04-51 only partly), 1 flaky (04-69, red 1 of 3, reworded).
"red" means the prediction was false; the test now asserts the observed truth. Test names are
`"<id>: ..."` in `lab/04-beam/test/*.exs`. Final suite after E6: `Result: 72 passed`, 3 runs, seeds 806046, 206179, 370822, 47.9-52.6 s each
(`logs/04-suite-3runs.log`). E6's 10 claims (04-70..79: 8 green, 2 red) are in the E6 table.

| id | claim (as predicted) | first run | final truth (the test asserts this) | test |
|---|---|---|---|---|
| 04-1 | spawn+raise: one :error event from the emulator, handler runs in :logger, domain [:otp], crash_reason in meta | red | one :error event, handler runs in :logger_proxy, NO domain, NO mfa; meta = pid, gl, time, error_logger %{tag: :error, emulator: true}, crash_reason (added by Elixir translator); msg translated to {:string, _} | `"04-1: ..."` |
| 04-2 | spawn+throw: crash_reason {{:nocatch,:boom},stack} | red | crash_reason {%ErlangError{original: {:nocatch, :boom}}, stack}: the throw kind is lost, looks like an error | `"04-2: ..."` |
| 04-3 | spawn+exit(:boom): nothing logged | green | nothing reaches any handler | `"04-3: ..."` |
| 04-4 | spawn+BIF badarg: logged as ArgumentError | green | same as 04-1, crash_reason {%ArgumentError{}, [{:erlang, :atom_to_binary, [1], _}]} | `"04-4: ..."` |
| 04-5 | spawn_link+raise: logged once; linked plain parent dies silently | green | one event; parent's death by link is not logged | `"04-5: ..."` |
| 04-6 | Task.start+raise: :error report {Task.Supervisor,:terminating} logged IN the task process, meta callers+crash_reason | green | domain [:otp, :elixir], meta callers, crash_reason, error_logger %{tag: :error_msg}, report_cb; report keys args/function/name/reason/process_label/starter; no mfa | `"04-6: ..."` |
| 04-7 | Task.start+exit(:boom): Task logs non-normal exits | green | logged, crash_reason {:boom, stack} | `"04-7: ..."` |
| 04-8 | Task exit :normal / {:shutdown,_}: nothing | green | nothing | `"04-8: ..."` |
| 04-9 | Task.async+await: task crash logged once, caller killed by link silently | green | one event, callers [caller] | `"04-9: ..."` |
| 04-10 | Task.Supervisor.async_nolink: logged once, yield gives {:exit,_}, meta has ancestors | red | logged once with callers; NO ancestors in meta; report.starter = caller | `"04-10: ..."` |
| 04-11 | Task.await timeout: caller exits {:timeout,{Task,:await,_}}, nothing logged | green | nothing logged (plain caller) | `"04-11: ..."` |
| 04-12 | exit(:kill) self or Process.exit(p,:kill): nothing logged | green | nothing | `"04-12: ..."` |
| 04-13 | Logger.error: handler runs in caller, domain [:elixir], mfa/file/line | green | as predicted; msg {:string, "hello"} | `"04-13: ..."` |
| 04-14 | :erlang.error(:foo) in plain process: ErlangError crash_reason | green | as predicted | `"04-14: ..."` |
| 04-15 | GenServer init raise (default config): start returns {:error,_}, nothing reaches handlers | green | nothing at all: the only report is a proc_lib crash report in domain [:otp,:sasl], stopped by the primary translator filter | `"04-15: ..."` |
| 04-16 | init raise with sasl on: proc_lib crash report with the full process snapshot | green | label {:proc_lib,:crash}, report [info_kw, neighbours]; info has initial_call, pid, registered_name, process_label, error_info, ancestors, message_queue_len, messages, links, dictionary, trap_exit, status, heap_size, stack_size, reductions; meta adds ancestors, initial_call, crash_reason | `"04-16: ..."` |
| 04-17 | handle_call raise: {:gen_server,:terminate} report nested under :report, handler in server process, client_info {pid,_,_} | red | report is FLAT: %{label,name,reason,log,state,last_message,process_label,client_info}; client_info = {pid, {pid, caller's current stacktrace}}; handler runs in the server; meta mfa/file/line point at gen_server internals | `"04-17: ..."` |
| 04-18 | handle_cast raise: last_message {:"$gen_cast",_}, client_info :undefined | green | as predicted (after flat-shape fix) | `"04-18: ..."` |
| 04-19 | handle_info throw: crash_reason {{:nocatch,:boom},_} | red | a throw in a gen_server callback is a RETURN VALUE: reason {:bad_return_value, :boom}, stacktrace [] | `"04-19: ..."` |
| 04-20 | {:stop, :normal/:shutdown/{:shutdown,_}}: nothing logged | green | nothing | `"04-20: ..."` |
| 04-21 | {:stop, :boom}: logged, crash_reason {:boom, []} | green | as predicted, no stacktrace | `"04-21: ..."` |
| 04-22 | terminate raises: reason = terminate exception | green | the original reason is lost from crash_reason | `"04-22: ..."` |
| 04-23 | GenServer.call timeout: caller exits {:timeout,_}; nothing logged | green | nothing; server keeps running | `"04-23: ..."` |
| 04-24 | stray message to use GenServer w/o handle_info: :error {GenServer,:no_handle_info}, process lives | green | domain [:otp,:elixir] | `"04-24: ..."` |
| 04-25 | Agent.get raising fun: Agent server crashes with gen_server report, last_message {:get,_} | green | as predicted | `"04-25: ..."` |
| 04-26 | gen_statem raise: {:gen_statem,:terminate} report | green (after flat fix) | reason is {class, reason, stack}; has queue, modules, state {name,data}; no last_message | `"04-26: ..."` |
| 04-27 | supervised child crash (default): only the child's gen_server report | green | supervisor child_terminated + progress are filtered | `"04-27: ..."` |
| 04-27s | with sasl: gen_server + proc_lib crash + child_terminated + progress | green | 4 events (+ start progress) | `"04-27s: ..."` |
| 04-28 | max intensity (default): supervisor dies :shutdown, not logged; only child reports | green | 2 child reports, supervisor giving up is invisible | `"04-28: ..."` |
| 04-28s | max intensity with sasl: {:supervisor,:shutdown} report | green | as predicted | `"04-28s: ..."` |
| 04-29 | brutal kill of supervised GenServer (default): nothing logged | green | nothing | `"04-29: ..."` |
| 04-29s | brutal kill with sasl: child_terminated reason :killed | green | as predicted; the ONLY trace a killed process leaves | `"04-29s: ..."` |
| 04-30 | Process.exit(trapping server, :boom) from non-parent: {:EXIT} message; no clause -> FunctionClauseError | green | as predicted | `"04-30: ..."` |
| 04-31 | Process.set_label in plain spawn: emulator event carries no label | green | label is nowhere in the event | `"04-31: ..."` |
| 04-32 | set_label in Task: report.process_label | green | report.report.process_label = {:job, 7} | `"04-32: ..."` |
| 04-33 | set_label in GenServer: report.process_label | green | as predicted | `"04-33: ..."` |
| 04-34 | backtrace_depth defaults to 8 and truncates; 64 keeps 21+ | red | 8 in a plain VM but ExUnit sets 20 (its :stacktrace_depth); truncation to 8 verified; 64 keeps 21+; and (2nd red) direct self-recursion at one call site collapses to one frame (down(20) -> 2 frames total) | `"04-34: ..."` |
| 04-35 | GenServer debug: [log: 5]: report.log has the last :sys events | green | [{:in, call}, {:out, reply, to, state}, ..., {:in, {:"$gen_cast", {:do,:raise}}}]: last message + replies + state after each reply | `"04-35: ..."` |
| 04-36 | dying process's Logger.metadata: in Task and GenServer reports, not in plain spawn | green | as predicted (plain spawn events are emitted in :logger_proxy) | `"04-36: ..."` |
| 04-37 | Application.stop: :info {:application_controller,:exit} | red | level :notice | `"04-37: ..."` |
| 04-38 | temporary app top sup killed: :info event only | red | :notice event only (exited :killed, type :temporary) plus nothing else | `"04-38: ..."` |
| 04-39 | with sasl: one Task crash = 2 events (Task report + proc_lib crash report) | red | 1 event: Task.Supervised spawns without proc_lib, so no crash report; a GenServer call crash = 2 events (gen_server + proc_lib crash), same meta.pid | `"04-39: ..."` |
| 04-40 | swallowed rescue, {:error,_} return, catch :exit: nothing reaches any handler | green | nothing | `"04-40: ..."` |
| 04-43 | exception_trace on a module sees a raise swallowed by its caller | red | first run saw nothing because the module was not loaded yet (see 04-49); once loaded: {:trace, pid, :exception_from, {Silent,:inner,0}, {:error, %RuntimeError{}}} | `"04-43: ..."` |
| 04-44 | raise+rescue in ONE function: exception_trace sees nothing; call trace on :erlang.error/_ sees it | green | as predicted: {:trace, pid, :call, {:erlang, :error, [%RuntimeError{}, :none, [error_info: ...]]}} | `"04-44: ..."` |
| 04-45 | BIF badarg rescued: invisible to :erlang.error tracing | red | atom_to_binary/1 IS visible (Erlang-level wrapper calls erlang:error/3); badarith, element/2, badmatch, case_clause raised by instructions are invisible | `"04-45: ..."` |
| 04-46 | {:error,_} returns visible via return_trace | green | {:trace, pid, :return_from, {Silent,:lookup,1}, {:error,:nope}}; filtering must happen in the tracer | `"04-46: ..."` |
| 04-47 | catch :exit on GenServer.call to dead pid visible via call trace on :erlang.exit/1 (one message) | red | TWO exit calls: gen.erl exit(:noproc) internally, then GenServer.call re-exits {:noproc, {GenServer,:call,_}}: control-flow exits are noisy | `"04-47: ..."` |
| 04-48 | two sessions trace one process independently; destroying one leaves the other | green | as predicted | `"04-48: ..."` |
| 04-49 | pattern set while module unloaded matches 0 fns; module stays untraced after load | green | as predicted: :trace.function returns 0, no messages after autoload | `"04-49: ..."` |
| 04-50 | {:silent,true}/silent flag suppresses call msgs but keeps exception_from | red | silent mode suppresses exception_from too (0 messages) | `"04-50: ..."` |
| 04-51 | trace costs: traced exception_trace >5x; untraced processes <2x; erlang:error pattern ~0 | red (untraced part) | baseline 2.6-3.1 ns/iter; pattern active but process NOT traced 13.6-14.8 ns (~4.5x, every process pays); exception_trace traced ~16 us/iter (~5000x, 4 msgs/iter); erlang:error/exit/throw call trace 2.6-3.4 ns (noise); setting {_,_,_} on 23,590 loaded functions takes 6-8 ms | `"04-51: ..."` |
| 04-52 | traced raise costs < 2x an untraced raise | red | ~6-7x on the raise path: 100k raises 5.8-7.0 ms untraced vs 41-43 ms traced = +0.35 us per raise (one message each) | `"04-52: ..."` |
| 04-53 | raise cost is O(stack depth) (found by accident) | green (written after observation) | 100k swallowed raises: 7.4 ms in a tail loop vs 5.03 s inside a `for` (100k-deep body recursion): ~48 us per raise at depth 100k | `"04-53: ..."` |
| 04-60 | a raising/exiting/throwing handler is removed; the event still reaches other handlers; OTP tells other handlers nothing | red | removed (all 3 kinds), caller unaffected, other handlers get the event; AND other handlers receive a :debug report [logger: :removed_failing_handler, handler, log_event, config, reason {class, reason, stack}] with meta internal_log_event: true | `"04-60: ..."` |
| 04-63 | handlers run in the caller: a 20 ms handler makes Logger.error take >= 20 ms | green | as predicted | `"04-63: ..."` |
| 04-64 | a handler logging from inside log/2 does not recurse into itself | red | it recurses with no OTP guard; only our counter cap (1000) stopped it | `"04-64: ..."` |
| 04-65 | 10k Logger.error from 100 procs: a sync handler receives all 10k | green | all 10,000 in 11-22 ms; no drop in :logger core, Elixir discard_threshold does not apply to :logger handlers | `"04-65: ..."` |
| 04-66 | logger_std_h (file) under 10k flood from 100 procs drops a large share | green | 500/10,000 written (burst limit 500 per 1 s window), plus mode-switch/flush notices in some runs | `"04-66: ..."` |
| 04-67 | logger_std_h burst: 2000 from one process -> ~500 written | green | 500/2000; no drop notice in the file within 1.2 s | `"04-67: ..."` |
| 04-68 | 10k plain-process crashes: the handler sees all 10k | red | 1,665-4,799 of 10,000 arrived (timing-dependent): :logger_proxy enters drop mode by setting system_logger to undefined, the VM then DISCARDS emulator error reports; only 2 :notice events ("logger_proxy switched from async to drop mode") say so, with no count | `"04-68: ..."` |
| 04-69 | 1 ms handler + 5k plain crashes: fewer than 5k survive | flaky (red 1 of 3) | logger_proxy queue overshoots its drop_mode_qlen 1000 (1,364-4,951 after 100 ms) because drop mode reacts late; delivered 3,455-5,000 | `"04-69: ..."` |

### E6. Relayed claims from 01/02 and the lead; routes to SASL reports (tests 04-70 .. 04-79, `test/g_routes_test.exs`) — verified

First run: 8 green, 2 red (04-76 was a harness bug; 04-79 contradicts the relayed "telemetry detaches silently").

| id | claim | first run | final truth |
|---|---|---|---|
| 04-70 | (02a) the handler for a gen_server / proc_lib / Task report runs in the dying process, so `Process.get` there reads *its* dictionary | green | true for gen_server, Task and proc_lib crash reports; `nil` for plain spawn (the handler runs in `:logger_proxy`) |
| 02b | plain-spawn crashes go through `:logger_proxy` and are dropped in drop mode | (04-1, 04-68) | already proven: 1,665-4,799 of 10k delivered |
| 02c | application exits are `:notice` | (04-37/38) | already proven |
| 04-71 | `:logger.add_primary_filter/2` **prepends**, so our filter runs before Elixir's `logger_translator` | green | `[lab_spy, logger_translator, logger_process_level]` (`logger_server.erl:391-400`: `[Filter|Filters]`) |
| 04-72 | GenServer.start `init` raise: *emitted* (proc_lib crash report), *dropped* by the translator | green | yes |
| 04-73 | bare `spawn` + `exit(:boom)`: *never emitted* | green | yes: our primary spy sees nothing |
| 04-74 | a linked Task caller dying with its task: only the task is emitted | green | the caller's death is never emitted |
| 04-75 | supervisor `child_terminated`, `start_error`, `shutdown` (max intensity): *emitted*, *dropped* | green | yes; the handler sees only the child's gen_server report |
| 04-76 | route A: sasl on + `{&:logger_filters.domain/2, {:stop, :sub, [:otp, :sasl]}}` on the console handler | red (harness) | ours: gen_server + proc_lib crash + child_terminated + progress; console: gen_server only |
| 04-77 | route B: our primary filter sees SASL reports and returns `:ignore`; the translator still stops them for every handler | green | yes: we get them, no handler (console included) prints them |
| 04-78 | route D: a monitor sees `:killed`, which logger never reports | green | yes |
| 04-79 | a raising `:telemetry` handler is detached; relayed claim: "silently" | red vs relay | **not silent**: detached, then `[:telemetry, :handler, :failure]` is executed with `kind/reason/stacktrace`, and one `:error` report in domain `[:telemetry]` is logged (`telemetry.erl:196-216`, 1.4.2). Also every `:telemetry.attach` logs an `:info` report |

So "dropped vs never emitted": **dropped by the primary translator filter** are the GenServer/`gen_statem`
`init` crash (proc_lib crash report), all proc_lib crash reports, and supervisor `start_error`,
`child_terminated`, `shutdown` and `progress`. **Never emitted by anyone** are `exit/1` in a plain process,
`exit(:kill)`/`Process.exit(pid, :kill)` on an unsupervised process, death by a link signal (the Task caller),
`{:shutdown, _}`/`:normal`, and caller-side timeouts. For those, only monitors or a `:procs` trace help.

**Routes ranked, least invasive first:**
1. **B: our own primary filter** (`:logger.add_primary_filter(:blackbox, {&Blackbox.filter/2, cfg})`).
   It is prepended, so it runs before the translator (04-71). It forwards `[:otp, :sasl]` events into our
   pipeline and returns `:ignore`. The translator then stops them as before, so the console stays exactly
   as the user configured it and no config changes (04-77). Costs: it runs for **every** log event in the
   calling process (keep it a pattern match plus a `send`/ETS insert). A crashing primary filter is
   removed like a handler (`logger_backend.erl:122-135`), so wrap it in `try`. It sees *untranslated*
   events (no `crash_reason`), so the lib must normalize the raw OTP reports itself; that is fine because
   it needs raw fields anyway. Risk: something that later rebuilds the primary filters (not observed;
   unknown whether `Logger.configure` does) would reorder them, so a watchdog should check that we are
   still first.
2. **A: `handle_sasl_reports: true`** plus a domain `:stop` filter on the `:default` handler (04-76).
   This works, but it changes a user-visible setting and a user-owned handler, and every other handler
   (file handlers, Sentry's) starts receiving SASL noise.
3. **Handler-level only**: impossible. The translator's `:stop` happens before any handler (04-15, 04-72).
4. **D: monitors / supervisor telemetry**: `Supervisor` emits no telemetry. A monitor sees `:killed`
   (04-78) but has no stack, state or report, and the lib would have to know every pid. Use it only for
   named processes the user opts in.

## What reaches a `:logger` handler, one table

Default = Elixir 1.20 defaults (`handle_otp_reports: true`, `handle_sasl_reports: false`). "sasl" = with the
translator filter set to `sasl: true`. Handler process: C = caller, D = dying process, P = `:logger_proxy`.

| failure | default | with sasl | level | label / shape | runs in | key data |
|---|---|---|---|---|---|---|
| raise/throw/error in `spawn`/`spawn_link` | 1 | 1 | error | `{:string, _}` (was `{fmt, args}`), no domain | P | `crash_reason`, pid; no mfa, label, metadata |
| `exit(reason)`, kill, death by link (plain) | 0 | 0 | | | | nothing |
| Task (start/async/nolink) crash or non-normal exit | 1 | 1 | error | `{Task.Supervisor, :terminating}`, `[:otp, :elixir]` | D | `callers`, `starter`, `process_label`, metadata |
| GenServer call/cast/info crash, `{:stop, bad}` | 1 | 2 (+proc_lib crash) | error | `{:gen_server, :terminate}` flat | D | `last_message`, `state`, `log`, `client_info` (+caller stack) |
| GenServer `init` crash | 0 | 1 | error | `{:proc_lib, :crash}` | D | full process snapshot |
| `:gen_statem` crash | 1 | 2 | error | `{:gen_statem, :terminate}` | D | `{class, reason, stack}`, `queue`, `state` |
| Agent crash | 1 | 2 | error | gen_server report | D | `last_message {:get, fun}` |
| `use GenServer` stray message | 1 | 1 | error | `{GenServer, :no_handle_info}` | D | process survives |
| supervisor restart | 0 extra | +child_terminated +progress | error/info | `{:supervisor, _}` | supervisor | child id, reason, restart type |
| supervisor max intensity | 0 extra | +`{:supervisor, :shutdown}` | error | | supervisor | |
| brutal kill of supervised child | 0 | 1 | error | child_terminated `reason: :killed` | supervisor | only trace of a kill |
| application stop / temporary app crash | 1 | 1 | **notice** | `{:application_controller, :exit}` | app master | `exited`, `type` |
| `Logger.error` | 1 | 1 | error | `{:string, _}`, `[:elixir]` | C | mfa/file/line of the call site |
| call/await timeout (caller side) | 0 | 0 | | | | only if the caller then dies logged |
| rescued / `{:error, _}` / `catch :exit` | 0 | 0 | | | | only tracing (E4) |
| failing handler removed | +1 | +1 | **debug** | `[logger: :removed_failing_handler, ...]` | C | reason with stack |
| logger_proxy drop mode | +1 | +1 | notice | "switched from async to drop mode" | P | no count |

## Findings table

| id | what | evidence | priority | proposal (one line) | size |
|---|---|---|---|---|---|
| F1 | SASL-domain reports (init crashes, restarts, give-ups, kills) are stopped by Elixir's primary filter before any handler | 04-15, 04-27..29, 04-72..77, `logger/utils.ex:11-13` | P0 | Add our own primary filter (it is prepended, so it runs before the translator) that forwards `[:otp, :sasl]` events to our pipeline and returns `:ignore`: no config change, the console stays unchanged | S |
| F2 | One crash = 1..4 events (gen_server + proc_lib + supervisor + progress) | 04-27s, 04-39 | P0 | Dedupe by `meta.pid` + a short window; prefer the richest (proc_lib crash report for snapshot, gen_server for last_message/state) and merge | M |
| F3 | Silent deaths: exit/kill/link/timeouts log nothing | 04-3, 04-12, 04-11, 04-23 | P1 | Optional: supervisor child_terminated covers supervised kills; plain processes only via a `:procs` trace or monitors; document as out of scope by default | M |
| F4 | Four event shapes; meta `mfa` is OTP internals | 04-1, 04-6, 04-17, 04-26 | P0 | Normalizer with one clause per label; take the culprit frame from `crash_reason` stack, never from meta mfa | M |
| F5 | Missing/short stacks: throw-as-return, `{:stop, r}`, depth 8, recursion collapse | 04-19, 04-21, 04-34 | P1 | Set `backtrace_depth` to 32 at start (config); fingerprint = kind + normalized reason + top in-app frames, fallback to label+module when stack is `[]` | S |
| F6 | Free "before" data: `:sys` log, mailbox, dictionary, `$callers`, metadata, `client_info` caller stack | 04-16, 04-17, 04-35, 04-36 | P1 | Store them as event fields with byte caps; offer `debug: [log: n]` opt-in helper for named GenServers | M |
| F7 | Swallowed exceptions visible only by tracing; `erlang:error/throw` call trace ~0 cost, +0.35 µs/raise | 04-40..52 | P2 | Opt-in "swallowed" sampler: own `:trace` session, `:all` processes, `{:erlang,:error,:_}`+`{:erlang,:throw,1}`, rate-limited tracer, embedded mode only | M |
| F8 | `exception_trace` / `{_,_,_}` patterns slow every process ~4.5x, traced ones ~5,000x | 04-51 | P0 (as a don't) | Never enable by default; only a time-boxed "debug this pid" action | S |
| F9 | Handler runs in caller / dying process / logger_proxy | 04-1, 04-13, 04-63 | P0 | `log/2` does only a bounded ETS insert or `send` to a buffer; no I/O, no calls | S |
| F10 | Crashing handler removed, reported only at :debug; no recursion guard | 04-60, 04-64 | P0 | `try` around all of `log/2`; `Process.put(:blackbox_in_handler, true)` guard; watchdog re-adds the handler and records "handler was removed" | S |
| F11 | VM drops plain-process crash reports under a flood (logger_proxy drop mode), uncounted | 04-68, 04-69 | P1 | Capture logger_proxy mode notices as "lost N unknown" markers; document `:logger.set_proxy_config/1`; own counters per fingerprint | S |
| F12 | `logger_std_h` shows 500/s at most | 04-66/67 | P2 | The UI, not the console, is the source of truth during incidents; say so in docs | S |
| F13 | Application exits are :notice | 04-37/38 | P1 | Handler level `:notice` with a filter that keeps only `{:application_controller, :exit}` and our own markers below `:error` | S |
| F14 | Tests lie about depth (ExUnit sets 20) | 04-34 | P2 | The lib's own tests set `backtrace_depth` explicitly | S |

## Recommendations for the lib

1. **Install sequence** (`Blackbox.attach/1`): set `backtrace_depth` (default 32); add our own
   **primary filter** (it is prepended, so it runs before Elixir's translator, 04-71/77) that
   hands `[:otp, :sasl]` events to our pipeline and returns `:ignore`, leaving the console and the
   user's config unchanged; add our handler at level `:notice`; start a watchdog that re-adds the handler
   and filter if either is removed, and puts the filter back first if the order changes.
2. **Handler `log/2`**: guard re-entrancy with a process-dictionary flag; `try` everything; drop
   `:info` and below except `{:application_controller, :exit}`, `removed_failing_handler`, and
   `logger_proxy` mode notices; copy only the needed fields (pid, label, reason/crash_reason, stack,
   last_message/state/log/client_info truncated to a byte cap, callers, ancestors, process_label,
   metadata) and `:ets.insert` into a bounded ring (or `send` to one buffer process with a
   `:counters`-based admission limit). No I/O, no GenServer calls.
3. **Normalizer** with one clause each for: emulator `error_logger: %{emulator: true}` (reason in
   `crash_reason`), `{:gen_server, :terminate}`, `{:gen_statem, :terminate}` (3-tuple reason),
   `{Task.Supervisor, :terminating}`, `{:proc_lib, :crash}`, `{:supervisor, :child_terminated |
   :shutdown}`, `{:application_controller, :exit}`, plain `Logger.error` strings/reports, and
   `{GenServer, :no_handle_info}`. Keep the kind (`:throw` is lost by the translator: recover it from
   `{:nocatch, v}`; `{:bad_return_value, v}` from GenServer throws).
4. **Dedupe**: key `{pid, reason-hash}` within ~1 s; merge the gen_server report (last_message, state,
   client_info) with the proc_lib crash report (mailbox, dictionary, links) and the supervisor report
   (child id, restart). Count supervisor restarts on the same issue.
5. **Fingerprint** must survive `[]` stacks and 8-frame truncation: kind + exception module (or
   normalized reason atom/tuple shape) + first in-app `{m, f, a}` frames (no lines), falling back to
   label + registered name/initial call.
6. **"Before" for free**: always keep `last_message`, `state` (inspected, capped), `:sys` log when
   present, the caller stack from `client_info`, `$callers`, `$ancestors`, `Logger.metadata`,
   `process_label`. Offer `Blackbox.debug_log(pid_or_name, n)` = `:sys.log(pid, {true, n})` for chosen
   servers (cost: agent 06).
7. **Silent failures**: ship an opt-in, time-boxed `Blackbox.Trace.swallowed/1` using its own
   `:trace` session on `erlang:error/1,2,3` and `erlang:throw/1` for `:all` processes, with a tracer
   that samples and rate-limits (it is a message flood under a raise flood). Refuse
   `exception_trace`/wildcard patterns except in a "trace this pid for 10 s" action.
8. **Floods**: treat `logger_proxy` drop mode notices as a "lost crash reports: unknown count"
   occurrence; document `:logger.set_proxy_config(%{drop_mode_qlen: ..., flush_qlen: ...})`; never rely
   on the console (`logger_std_h` shows 500/s).
9. **Beyond logger** (for the ADR's capture surface): kills and exits of unsupervised processes are
   invisible to logger; if wanted, a `:procs` trace on `exit` events (agent 06/08 cost) or monitors on
   named processes. Application crashes arrive at `:notice`.
10. **Test the lib like this lab**: a `:logger` handler that forwards to the test pid, `max_cases: 1`,
    explicit `backtrace_depth`, SASL filter flipped per test, and flood tests that assert bounds, not
    exact counts, for anything that passes through `:logger_proxy`.

## Sources

- **verified**: `lab/04-beam/` (mix project; `lib/beam_lab/capture.ex` capture handler;
  `test/support/case.ex`, `test/support/workers.ex`; tests `a_processes`, `b_otp`, `c_details`,
  `d_trace`, `e_trace_cost`, `f_handler_safety`). Logs: `logs/04-lab.log` (primary config, suite
  runs), `logs/04-events.log` (shape of every captured event per test), `logs/04-run-*.log` (first
  runs incl. red output), `logs/04-cost.log`, `logs/04-flood.log`, `logs/04-sys-log.txt`,
  `logs/04-suite-3runs.log`, `logs/04-claims.tsv`, `logs/04-flood-std_h.txt`, `logs/04-burst-std_h.txt`.
- Machine: Apple M3 Pro (`sysctl -n machdep.cpu.brand_string`), macOS Darwin 24.6.0, Elixir 1.20.4
  compiled with OTP 28, OTP 28.5.0.6 (erts 16.4.0.6, kernel 10.6.3.4, stdlib 7.3.0.2), JIT, 11 schedulers.
- **read**: Elixir 1.20.4 `lib/logger/lib/logger/utils.ex:11-99` (translator primary filter, process
  level filter), `lib/logger/lib/logger/translator.ex:150-170, 495-520` (crash_reason, callers,
  ancestors, `:logger_enabled` dictionary opt-out, user metadata), `lib/ex_unit/lib/ex_unit/runner.ex:45`
  (backtrace_depth), `lib/elixir/lib/task/supervised.ex:9-17,125` (plain spawn, process_label);
  OTP 28.5 kernel `src/logger_proxy.erl:65-80,104-109,150-165` (emulator path, defaults, drop mode via
  `system_logger`), `src/logger_backend.erl:50-75` (failing handler removal), `src/logger_olp.erl:133-134`
  (burst defaults), `src/logger_server.erl:391-400` (filters prepended), `src/logger_backend.erl:122-135` (failing filter removal); telemetry 1.4.2 `src/telemetry.erl:130-140,196-216` (attach :info log, failure event + :error log); `trace` module exports (OTP 27+ sessions).
