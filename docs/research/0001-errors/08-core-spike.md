# 08 Core spike: capture, fingerprint, bounded pipeline, Postgres, breadcrumbs

Agent 08, 2026-09-27. Lab: `lab/08-spike/` (Mix project `spike`, Elixir 1.20.4 / OTP 28,
Postgres 18.6 local, Apple M3 Pro). Logs: `logs/08-*.log`. TDD: every test was
written before its first run; first outcome recorded in the claims table.

## Summary for the lead

1. **The core works end to end and is small**: ~440 lines in `lab/08-spike/lib` (handler, event, buffer, store, crumbs); 40 ExUnit tests, the last 3 full runs green (`mix test --include flood`, 57 s; seeds 143350, 785301, 630634); one earlier flake (08-27 heap bound), fixed and explained below.
2. **Nothing is lost under load**: 10k, 20k, 50k, 100k and 200k `Logger.error`/s, 10k Task crashes/s, 10k plain-spawn crashes/s: in every run **sent == counted in Postgres, 0 dropped**. Aggregating by fingerprint in the buffer (count exact, keep 3 samples) is what makes this cheap: one upsert row per fingerprint per 100 ms.
3. **Bounded and non-blocking**: the handler only does `:atomics.add_get` + `send` (cap 10 000 in flight, then drop and count; proven exact in 08-18). Buffer process max 0.2..9 MB (heap garbage, 1 live issue), VM +1..4 MB, app probe p99 30..98 µs under a 10k/s flood (idle 5..37 µs).
4. **Survives its own failure modes**: a writer that raises (08-14), hangs (killed after 500 ms, 08-15), or the DB being down for 3 s at 10k errors/s (08-30): the buffer merges failed batches back, backs off 50 ms..5 s, memory stays at 2 pending issues, and **30 000 of 30 000 land after recovery**. The handler survives a poison event (08-17).
5. **No recursion, with one line**: the buffer and writer set `Logger.metadata(spike: true)`, and `log/2` ignores that metadata first thing. What the writer logs or how it crashes is never captured (08-16).
6. **Breadcrumbs are nearly free in the process dictionary**: 0.16 µs per `crumb/1`, +0.3 µs for a `Logger.debug` turned into a crumb, 3.2 KB per process. The handler runs *inside the dying process* for Task/gen_* crashes, so it reads the ring directly; a Task also carries its caller's crumbs via `process_info(caller, {:dictionary, key})` (08-19..08-22). Agent 06 found the same independently.
7. **Dedupe needs no shared state**: one failure reported twice (telemetry exception + crash report, or gen_server + proc_lib report) happens in one process, so the last `{fingerprint, message}` in the pdict (1 s window) drops the twin. Supervisor `child_terminated` reports are skipped when the child already reported an exception, and kept when they are the only witness (`:killed`, 08-34/35); a supervisor giving up is its own issue (08-36). Unlike Sentry's whole-event hash with its silent 30 s window (01), every repeat is still counted.
8. **Fingerprint = kind + type + top 3 non-stdlib frames `{module, function (fun index stripped), arity}`**: it survives a 40-line shift and a new anonymous function; logs are masked for numbers, pids and uuids; exits group by shape (`{:timeout, _}`); call args never enter it, so 3 call timeouts with different args are 1 issue (08-37, the Sentry #933 flood).
9. **Three traps the lib must design around (all proven red)**: Elixir's translator drops proc_lib/SASL crash reports AND any report with an unknown `label` for every handler; `Logger.configure(handle_sasl_reports: true)` at runtime does nothing; `meta.mfa` of an OTP crash is the logging site (`{:gen_server, :error_info, 7}`), not your code.
10. **Cost trap found and fixed**: `:application.get_application/1` (11 µs) and `Exception.format_stacktrace_entry/1` (~20 µs a frame) made one crash cost 1.4 ms in the failing process. Now 33..40 µs per crash and 13..16 µs per `Logger.error`. Formatting happens in the buffer, only for kept samples. Also a real bug: comparing `System.monotonic_time` with 0 (it is negative) silently stopped timed writes (08-31, red then green).

## Design of the spike (as built)

```
failing process                              Spike.Buffer (GenServer)           Task under Spike.TaskSup
---------------                              ------------------------           ------------------------
:logger handler log/2 ----\                                                     Logger.metadata(spike: true)
  level < error: crumb     |  {fp, type, sample}   pending: %{fp => issue}      writer.(batch)
  into own pdict ring      |  atomics in-flight    count += 1                   = Store.write(Repo, batch)
  level >= error:          +--- cap 10k ------->   keep <= 3 samples  -- tick 100 ms -->  one transaction:
  Event.from_log           |  (else drop+count)    (format stack +    or flush/0        upsert issues by fingerprint
:telemetry handler --------/                        crumbs only here)                   (count = count + EXCLUDED.count)
  [:phoenix|:bandit|:oban...,:exception]            max 1 000 fingerprints              insert occurrences (samples)
  Event.from_telemetry                              one writer at a time, killed after 500 ms
dedupe: last {fp, msg} in pdict, 1 s                failed/crashed/killed -> merge batch back, backoff 50 ms..5 s
```

Files (`lab/08-spike/`): `lib/spike.ex` (crumb/1, stats/0 over one `:atomics` array),
`lib/spike/handler.ex` (both handlers, all wrapped in `catch`), `lib/spike/event.ex` (normalize,
fingerprint, supervisor rule, `finish/1`), `lib/spike/crumbs.ex` (pdict ring, `{count, list}`, trimmed
to 20 when it reaches 40, raw terms), `lib/spike/buffer.ex`, `lib/spike/store.ex` (two tables, SQL in
`setup!/1`), `test/support/{sink,load}.ex` (test writer, paced load, latency probe, memory sampler).
Schema: `issues(id, fingerprint unique, type, title, count bigint, first_seen, last_seen, status)`,
`occurrences(id, issue_id -> issues, payload jsonb, inserted_at)` with index `(issue_id, id desc)`.

What the spike deliberately does not do (the ADR decides): SASL on by default (tests 08-7/34/35 show
it works when switched on via the primary filter), a UI, scrubbing, source context, retention of old
occurrences, trace sessions, system snapshots (agent 06 measured those), request/conn capture
(agent 05).


## Experiments

### E0 Probe: what a handler really receives (before designing)

`lab/08-spike/probe/shapes.exs`, raw output in `logs/08-probe-shapes.log` (verified, OTP 28, Elixir 1.20.4):

| failure | handler runs in | msg form | domain | `crash_reason` meta |
|---|---|---|---|---|
| `spawn(fn -> raise end)` | `:logger_proxy` (0.72), NOT the dead process | `{:string, "Process ... raised an exception ..."}` (translated) | none | yes |
| `:proc_lib.spawn(fn -> raise end)` | nothing arrives | - | would be `[:otp, :sasl]` | - |
| `Task.start(fn -> raise end)` | the crashing Task process | `{:report, %{label: {Task.Supervisor, :terminating}}}` | `[:otp, :elixir]` | yes, plus `:callers` |
| GenServer raise in `handle_call` | the crashing GenServer | `{:report, %{label: {:gen_server, :terminate}, last_message, state}}` | `[:otp]` | yes, plus `:mfa` |
| `Logger.error("...", user_id: 5)` | the caller | `{:string, "..."}` | `[:elixir]` | no |

Why `:proc_lib.spawn` is silent: Elixir installs a *primary* filter
`logger_translator: {&Logger.Utils.translator/2, %{sasl: false, ...}}`
(`:logger.get_primary_config()`), and primary filters run before every handler.
`handle_sasl_reports: false` is the default. So the proc_lib crash report (the one that
carries `dictionary`, `ancestors`, `process_label`) never reaches ANY handler by default.
Consequence for the design: read the crashing process's dictionary and label *inside* `log/2`
with `Process.get/0` / `Process.get_label/0` (the handler runs in that process for Task and
gen_* crashes), and treat `crash_reason` metadata as the structured source of truth.

### E1 Capture + fingerprint + pipeline + store + crumbs: first TDD round

Tests written first (`test/*.exs`), run once against nothing (26/26 red, `logs/08-run-00-red.log`:
modules missing), then the spike was written, then run (`logs/08-run-01-first.log`): **21/26
green, 5 red.** The five reds, what really happens, and the corrected assertion:

1. **08-2 red**: `meta.mfa` of a gen_server crash is `{:gen_server, :error_info, 7}`, the
   *logging site*, not the GenServer module. The module is only in the stacktrace (and in
   `crash_reason`). Assertion now pins `"{:gen_server, :error_info, 7}"` and the top frame
   `Gs.handle_call/3`. Lesson: never group or title by `meta.mfa` for OTP reports.
2. **08-7 red**: `Logger.configure(handle_sasl_reports: true)` at runtime returns `:ok` and
   changes nothing: the primary `logger_translator` filter keeps `sasl: false`
   (probe `logs/08-probe-poison.log`, now test 08-7a). Swapping the primary filter config
   (`remove_primary_filter` + `add_primary_filter` with `sasl: true`) does enable it; with that,
   a `:proc_lib.spawn` crash is captured and a GenServer crash (gen_server report + proc_lib
   report, both logged by the dying process) is still ONE event thanks to the per-process dedupe.
3. **08-8 red**: `exit({:shutdown_like, :oops})` in a plain `spawn` reaches no handler at all:
   the emulator logs only *errors* of non-proc_lib processes, never exits (now test 08-8b).
   In a Task it is captured with type `exit {:shutdown_like, _}`.
4. **08-15 red, the claim holds**: a hung writer is killed after `writer_timeout` (500 ms);
   the batch merged back and was retried into a *second* hung task before the test swapped
   writers. With one more timeout of waiting, the count arrives exactly (1). Test fixed, not the code.
5. **08-17 red, poison never arrived**: `:logger.log(:error, %{label: :poison}, meta)` is
   dropped by Elixir's translator (`Logger.Translator.translate/4` returns `:skip` for a report
   with an unknown `label`), so NO handler sees it (new test 08-17b, green). A poison that does
   arrive (`Logger.error("poison", crash_reason: {:x, :bad})`, the stacktrace is not a list)
   makes normalization raise inside `log/2`; the `catch` counts it (`handler_errors` +1) and the
   handler stays attached.

Final: **29/29 green**, `mix test --seed 1`, 12.4 s (`logs/08-run-02.log`).

Design facts this round proved (all in the test names):
- Handler runs in the failing process for Task/gen_* crashes and for `Logger.error`, so the
  **process dictionary is the breadcrumb store for free**: `Process.get` in `log/2` sees the
  dying process's crumbs (08-19, 08-20, 08-22). For a Task, the caller's crumbs are read with
  `:erlang.process_info(caller, {:dictionary, :spike_crumbs})` (OTP 26+, copies one key only),
  so a crash in a Task carries the request's breadcrumbs (08-21). A plain `spawn` crash is
  logged via `:logger_proxy` after the process died: no crumbs, no label (08-23).
- Dedupe of "one failure, two reports" needs **no shared state**: both reports are emitted in
  the same process, so the last `{fingerprint, message}` + timestamp in the pdict (1 s window)
  drops the second (08-5 telemetry+crash, 08-7 gen_server+proc_lib).
- Fingerprint = sha256 of `{kind, type, top 3 frames outside elixir/stdlib/kernel/logger as
  {module, function-with-fun-index-stripped, arity}}`; for `:log` the message with numbers,
  pids, refs and uuids masked; for exits the reason's shape (`{:timeout, _}`). Survives a
  40-line shift (08-9) and a new anonymous function earlier in the module (08-10); changes with
  the function or the exception type (08-11).
- Pipeline: handler -> `send` guarded by an `:atomics` in-flight counter (cap 10 000;
  beyond it the handler drops and counts, 08-18: exactly 500 dropped of 10 500 with the
  buffer suspended, mailbox <= cap) -> Buffer aggregates by fingerprint (count exact, 3
  samples) -> one writer Task at a time under `Task.Supervisor.async_nolink`, killed after
  500 ms -> failed batches merge back (counts survive, backoff 50 ms..5 s). A raising writer:
  buffer pid unchanged, handler attached, 100 of 100 counted after the writer is fixed (08-14).
  Writer processes set `Logger.metadata(spike: true)`, and the handler ignores that metadata
  first thing, so what the writer logs or how it crashes is never captured (08-16).
- Store: `insert_all` with `on_conflict: update count = issues.count + EXCLUDED.count`,
  `conflict_target: :fingerprint`, `returning [:id, :fingerprint]`, then occurrences, in one
  transaction; 8 concurrent writers x 25 upserts of one fingerprint = exactly 200 (08-25);
  DB down = `{:error, _}` in < 2 s, not a crash (08-26).

### E2 Floods, DB down, costs (tests 08-27 .. 08-33, `test/flood_test.exs`, `test/cost_test.exs`, tag `:flood`)

Load generator (`test/support/load.ex`): 10 (or 20) producer processes, paced in 10 ms slices, hit
the target rate within 0.1 %. App latency = a probe process doing `Agent.get` round trips every
1 ms, p50/p99/max in µs. Memory = buffer process `:memory` + `message_queue_len` + VM
`:erlang.memory(:total)`, sampled every 50 ms. Writer = the real Postgres store unless noted.
Machine: Apple M3 Pro, shared with 7 other research agents running their own labs, so absolute
µs are noisy (the no-handler baseline moved 0.6 to 2.2 µs between runs); ratios are the signal.

**A bug the flood test found (red, then fixed with a red/green regression test 08-31).**
The first flood run's DB-down test said `writer_failures=0` while the DB was down for 3 s. Cause:
`retry_at` started at `0` and the tick wrote only when `System.monotonic_time(:millisecond) >=
retry_at`; **BEAM monotonic time is negative** (`-576460751917` on this node,
`logs/08-probe-down.log`), so the timed tick never wrote and only forced flushes did (the earlier
tests always called `flush/0`, which hid it). Fix: `retry_at: nil` when there is no backoff.
Test 08-31 ("without any flush call, the 100 ms tick writes a batch within 400 ms"): red on the old
code (`logs/08-run-04-tick-red.log`), green on the fix (`logs/08-run-05-tick-green.log`).

Results over the three full runs after the fix (`logs/08-flood.log`, runs 1-3):

| test | load | outcome (min..max over 3 runs) |
|---|---|---|
| 08-27 | 10k `Logger.error`/s x 5 s, Postgres writer | sent 50 000, **dropped 0, DB sum(count) 50 000 exact**, 1 issue row; buffer process max 1.2..3.0 MB; mailbox max 13..73; VM total +1.0..3.4 MB; probe p99 idle 5..37 µs vs flood 30..98 µs, max 271..538 µs |
| 08-28 | 10k `Task.start(fn -> raise end)`/s x 3 s | 30 000 crashes, **30 000 captured, 30 000 counted in DB** |
| 08-29 | 10k plain `spawn(fn -> raise end)`/s x 3 s (all through `:logger_proxy`) | 30 000 / 30 000 / 30 000: the proxy did not drop at this rate |
| 08-30 | DB down (repo on a closed port) + 10k errors/s x 3 s, then DB back | 5 writer failures with backoff 50..800 ms, pending stays at **2 issues** (the flood + Postgrex's own "failed to connect" log), buffer max 1.1..3.0 MB, VM +1.1..2.2 MB, probe p99 34..85 µs; **after recovery 30 000 of 30 000 stored** |
| 08-32 | ramp 20k, 50k, 100k, 200k `Logger.error`/s x 2 s, 20 producers | every rate hit (199.8k/s achieved), **dropped 0 at every rate, sent == stored**, mailbox max 17..628, buffer max 0.4..3.6 MB |
| 08-33 | per call, 50k loop | see below |

Per-call cost in the caller (08-33, three runs):

| operation | µs/call |
|---|---|
| `Logger.error` with no handler (baseline) | 0.63..0.73 |
| `Logger.error` captured (normalize + fingerprint + atomics + send) | 12.7..16.3 |
| `Logger.debug` recorded as a crumb by the handler | 0.93..1.07 (baseline 0.61..0.73, so +0.3 µs) |
| `Spike.crumb/1` (pdict ring, raw term) | 0.16..0.17 |
| `Event.from_log` on a gen_server crash, 12 frames, 20 crumbs | **33..40** (first version: **1 408**) |
| `Event.finish` in the buffer (format stack + crumbs), only for kept samples | 218..287 |
| ring of 20..40 crumbs in the pdict | 3 224 B |
| one sample, `term_to_binary` | 2 139 B |

Why the first normalize took 1.4 ms (profiled, `logs/08-probe-prof.log`, `logs/08-probe-tprof.log`):
`:application.get_application/1` costs **11 µs a call even for a loaded module** (it matches over
the application controller's table), and `Exception.format_stacktrace_entry/1` costs **18..24 µs a
frame** because it does the same lookup to print `(app vsn)`. Fixes: the set of elixir/stdlib/
kernel/logger/telemetry modules is built once into `:persistent_term`; stack and crumb formatting
moved out of the failing process into the buffer and runs only for the <= 3 samples kept per
fingerprint (so a flood of one error formats 3 stacks, not 50 000). After that, `tprof` shows no
hotspot: `inspect/2` of pid, state and last message, OTP 28's `re:import/1` (an `~r` literal is
re-imported on every call on OTP 28) and `Keyword.get` each take 3..7 %.

Reading of the numbers: the pipeline is not the bottleneck anywhere up to 200k errors/s, because
the buffer does O(1) work per message (map update) and the writer sees one row per fingerprint per
100 ms tick. The caller pays ~15 µs per captured error and ~35 µs per captured crash; a request that
logs one error pays that once. The `:atomics` bound (10 000 in flight) was never reached by real
load, only when the buffer was suspended (08-18). App latency p99 rose from single-digit tens of µs
to <= 100 µs under a 10k/s flood on a shared laptop, always under the 2x-or-1 ms bound.

### E3 Supervisor reports with SASL on (tests 08-34, 08-35), after reading 04

Agent 04 found that with SASL on, one supervised child crash makes 4 events (gen_server, proc_lib,
supervisor `child_terminated`, supervisor progress) and that a brutal kill of a supervised child is
visible ONLY as `child_terminated` with `reason: :killed`. Tests written first:
- **08-34 red**: a crashing supervised GenServer gave `[{"ArgumentError", 1}, {"log", 1}]`: the
  `child_terminated` report has **no `crash_reason` metadata** (it is logged by the supervisor, a
  different pid), so the per-process dedupe cannot see it and it fell through as a "log" event.
  (The progress report is `:info`, so it only became a crumb in the supervisor's pdict.)
- **08-35 red**: a brutal kill gave `[{"log", 1}]` instead of an `exit :killed` issue.
- Fix (`Spike.Event.from_log/1`, one clause): for `{:supervisor, :child_terminated}`, skip it when
  the reason is `{exception, stack}` or `{{:nocatch, _}, stack}` (the child reported it itself);
  otherwise capture it as `{:exit, reason}` with the offender's pid. Both green (`logs/08-run-11-sup-fixed.log`).

### E4 Report 01 (sentry-elixir) folded in: supervisor give-ups, call timeouts, in-process cost

The lead relayed four points from `01-sentry.md`. Answers, with two new tests written first:

1. **Supervisor restarts / give-ups.** With SASL on (the primary-filter swap), the spike now captures
   a supervisor reaching max restart intensity. Test **08-36**: first run **red twice**. First the
   test's second call raced the restart (`:noproc`). Then the real red: the `{:supervisor, :shutdown}`
   report has no `crash_reason` meta and fell through as a "log" event. Fix: one clause in
   `Event.from_log/1` turns it into `exit :reached_max_restart_intensity`. Final: 2 child crashes
   (one fingerprint) + 1 give-up = 2 issues. Restarts after an exception already reported by the
   child are not new issues (08-34). A restart after a `:kill` is (08-35). Progress reports
   (`:info`) become crumbs in the supervisor's own pdict only.
2. **No blocking work in the crashing process.** Sentry pays 52..62 us per crash there and blocks
   50 ms+ when its backend is slow (01). The spike does no I/O in the caller: 33..40 us per crash,
   13..16 us per `Logger.error` (08-33). Neither depends on the backend: with the DB down, or the
   writer hung, app probe p99 stayed at 34..85 us (08-30, 08-15), because the caller only does an
   `:atomics` add and a `send`.
3. **Dedupe by identity, not by hashing the whole event.** Sentry's `Dedupe` hashes the full event
   (incl. request/extra), so PlugCapture + the logger handler double-report (01, lab 01-5). It also
   drops repeats within 30 s silently, with no count (01-6/7). The spike marks each capture in the
   failing process's pdict (the New Relic idea from 02) and drops only the in-process twin within 1 s
   (08-5, 08-7). Every repeat still counts: counts are exact up to 200k/s (08-32).
4. **No call args in the fingerprint (Sentry #933).** Test **08-37**: three `GenServer.call`
   timeouts from Tasks, each with a different pid, argument and ref, give **one issue, count 3**
   (`exit {:timeout, _}`). The first run was red on a test flaw: the callee was an Agent, which also
   crashed on the unknown call. That second issue was itself grouped 3 -> 1
   (`FunctionClauseError` with 3 different `last_message`s), because the fingerprint uses arity,
   not args. The callee is now a process that never replies.

Final after E4: **40 tests, 0 failures, 3 of 3 full runs** (seeds 143350, 785301, 630634;
`logs/08-run-final2-{1,2,3}.log`).

## Claims table

All tests live in `lab/08-spike/test/`. "First run" means the first run of that test after it was
written. 08-7a, 08-8b and 08-17b were written after a probe had already shown the behaviour, so their
green first run is not independent evidence. Final suite (after E4): **40 tests, 0 failures**, 3 of 3 full runs (seeds 143350, 785301, 630634). Before E4: **38 tests, 0 failures**, `MIX_ENV=test mix
test --include flood`, the last 3 full runs green (seeds 72883, 844876, 406893; `logs/08-run-final-{2,3,5}.log`).
Run final-1 (seed 383334) had one failure, 08-27, at the old 5 MB heap bound.

| id | claim | first run | final truth | test (file) |
|---|---|---|---|---|
| 08-1 | a raise in a plain spawn becomes one event with type, stacktrace, pid | green | same (via `:logger_proxy`, translated string + `crash_reason`) | capture |
| 08-2 | a GenServer crash is one event with last_message, state and mfa naming the GenServer | **red** | `meta.mfa` is `{:gen_server, :error_info, 7}` (the logging site); the module is only in the stacktrace | capture |
| 08-3 | a Task crash carries `$callers` and the process label | green | same (label read in the dying process) | capture |
| 08-4 | `Logger.error` without a crash is an event of kind `:log` | green | same | capture |
| 08-5 | a telemetry exception then the same crash is one occurrence (source telemetry) | green | same, via pdict dedupe | capture |
| 08-6 | a `:proc_lib.spawn` crash reaches no handler under Elixir defaults | green | same (translator filter `sasl: false`) | capture |
| 08-7a | `Logger.configure(handle_sasl_reports: true)` at runtime does not touch the filter | green (after probe) | same: filter keeps `sasl: false` | capture |
| 08-7 | with SASL on, a proc_lib crash is captured and a GenServer crash is still 1 event | **red** (used `Logger.configure`) | green when the primary filter is replaced with `sasl: true` | capture |
| 08-8 | exit and throw are kinds of their own (exit in a plain spawn) | **red** | a plain spawn's `exit/1` is never logged; in a Task: `exit {:shutdown_like, _}` and `throw` | capture |
| 08-8b | `exit/1` in a plain spawn reaches no handler | green (after probe) | same | capture |
| 08-34 | with SASL on, a supervised GenServer crash is 1 event | **red** (`child_terminated` became a "log" event) | green after skipping `child_terminated` whose reason is an exception | capture |
| 08-35 | with SASL on, a brutal kill of a supervised child is 1 event `exit :killed` | **red** | green: `child_terminated` is captured as `{:exit, reason}` when the child could not report | capture |
| 08-36 | with SASL on, a supervisor reaching max restart intensity is captured besides the child crashes | **red** (a test race, then the `{:supervisor, :shutdown}` report became a "log" event) | green after one clause: `exit :reached_max_restart_intensity` | capture |
| 08-37 | `GenServer.call` timeouts with different pids, args and refs are ONE issue | **red** (a test flaw: the Agent callee crashed too) | green: 1 issue, count 3; the Agent crashes also grouped 3 -> 1 | capture |
| 08-9 | the same bug shifted 40 lines keeps its fingerprint | green | same | fingerprint |
| 08-10 | a new anonymous fn earlier in the module keeps the fingerprint | green | same (`-fun-N-` stripped) | fingerprint |
| 08-11 | a different function or exception type changes the fingerprint | green | same | fingerprint |
| 08-12 | log messages differing in ids, pids, uuids share a fingerprint | green | same | fingerprint |
| 08-13 | exit reasons with different pids/refs share a fingerprint by shape | green | same | fingerprint |
| 08-14 | a writer raising on every batch: buffer and handler survive, no loop, counts kept | green | same (100 of 100 after the fix) | pipeline |
| 08-15 | a hung writer is killed after the timeout and its batch retried | **red** (test too impatient) | same claim; the retry went into a second hung task first | pipeline |
| 08-16 | what the writer logs or how it crashes is never captured | green | same | pipeline |
| 08-17 | a poison event that makes normalization raise does not detach the handler | **red** (the poison never arrived) | green with a poison that arrives (`Logger.error` with a non-list stacktrace); `handler_errors` +1 | pipeline |
| 08-17b | a report with an unknown `label` is dropped by the translator before any handler | green (after probe) | same (`Logger.Translator.translate/4` returns `:skip`) | pipeline |
| 08-18 | the in-flight bound drops and counts instead of growing | green | exactly 500 of 10 500 dropped with the buffer suspended; mailbox <= cap | pipeline |
| 08-31 | without any flush, the 100 ms tick writes within 400 ms | **red on the old code** | green after the `retry_at: nil` fix (monotonic time is negative) | pipeline |
| 08-19 | manual crumbs in a Task arrive with its crash, in order, last 20 | green | same | crumbs |
| 08-20 | `Logger.info`/`debug` in the process become crumbs by themselves | green | same | crumbs |
| 08-21 | a Task crash carries its caller's crumbs via `$callers` | green | same (`process_info(pid, {:dictionary, key})`) | crumbs |
| 08-22 | a GenServer crash carries the crumbs recorded in the callback | green | same | crumbs |
| 08-23 | a plain spawn crash carries no crumbs | green | same (the handler runs in `:logger_proxy`) | crumbs |
| 08-24 | upsert by fingerprint: counts add up, 1 row per fingerprint, samples become occurrences | green | same | store |
| 08-25 | 8 concurrent writers x 25 upserts of one fingerprint = exactly 200 | green | same | store |
| 08-26 | the DB down is `{:error, _}`, not a crash, in < 2 s | green | same (~0.58 s with `queue_target` 50) | store |
| 08-27 | 10k `Logger.error`/s x 5 s: 0 drops, buffer bounded, p99 < 2x idle, DB exact | green (the tick bug hid) | same claims; heap bound flaky at 5 MB (9.2 MB once), holds at 20 MB | flood |
| 08-28 | 10k Task crashes/s x 3 s: every crash counted | green | same | flood |
| 08-29 | 10k plain spawn crashes/s x 3 s through `:logger_proxy`: every crash counted | green | same | flood |
| 08-30 | DB down during 10k errors/s: app fine, memory flat, all counted once back | **red** (`writer_failures` 0: the timed tick never wrote) | green after the fix: 5 failures, 30 000 of 30 000 stored | flood |
| 08-32 | 20k..200k errors/s: the bound holds, sent == stored + dropped | green | same, 0 dropped at every rate | cost |
| 08-33 | per-call costs: capture < 20 µs, crumb < 2 µs, normalize < 200 µs | **red** (normalize 1 408 µs; later capture 24 µs on a busy machine) | green: capture 13..16 µs, crumb 0.16 µs, normalize 33..40 µs; bounds set to the observed truth x2 | cost |

## Findings table

| id | what | evidence | priority | proposal (one line) | size |
|---|---|---|---|---|---|
| F1 | Elixir's primary translator filter drops `[:otp, :sasl]` reports (proc_lib crash, supervisor) for **every** handler; `Logger.configure(handle_sasl_reports: true)` at runtime does nothing | 08-6, 08-7a, 08-7; agents 04 and 06 agree | P0 | read context in the dying process; offer `sasl: true` as an install option that swaps the primary filter config | S |
| F2 | the translator also `:skip`s any report whose `label` it does not know, for every handler | 08-17b, `logs/08-probe-poison.log` | P1 | document it; libraries that log custom-label reports are invisible unless they use `Logger.error` | S |
| F3 | `meta.mfa` of an OTP crash is `{:gen_server, :error_info, 7}` | 08-2 | P1 | never group or title by `meta.mfa`; use `crash_reason` + stack | S |
| F4 | plain `spawn`: errors arrive via `:logger_proxy` (no pdict, no label), exits never arrive | 08-1, 08-8b, 08-23 | P2 | document; recommend Task/proc_lib; nothing to capture | S |
| F5 | one failure makes 2 to 4 reports; the in-process ones dedupe with a pdict key, the supervisor one by a reason rule | 08-5, 08-7, 08-34, 08-35 | P0 | pdict `{fp, msg}` 1 s key + the `child_terminated` rule; no ETS, no locks | S |
| F6 | `:application.get_application/1` 11 µs; `Exception.format_stacktrace_entry/1` ~20 µs a frame | `logs/08-probe-prof.log` | P0 | cache the stdlib module set in `:persistent_term`; format only in the buffer, only kept samples | S |
| F7 | `System.monotonic_time/1` is negative; a `>= 0` guard silently disabled timed writes | 08-31 red/green, `logs/08-probe-down.log` | P1 | use `nil` for "no deadline"; a tick test without `flush/0` | S |
| F8 | aggregating by fingerprint in the buffer keeps counts exact to 200k errors/s with 0 drops | 08-27, 08-32 | P0 | buffer = map fingerprint -> {count, first/last, 3 samples}, not a queue of events | S |
| F9 | failed batches merged back keep counts through a 3 s DB outage at 10k/s with 2 pending entries | 08-30 | P0 | merge-back + capped exponential backoff; memory bounded by distinct fingerprints | S |
| F10 | recursion is prevented by process metadata on the tracker's own processes | 08-16 | P0 | `Logger.metadata(blackbox: true)` in buffer + writer; first clause of `log/2` ignores it | S |
| F11 | a poison sample that makes the writer raise every time would be retried forever | not tested (reasoning from 08-14's design) | P1 | after N consecutive failures, retry the batch without samples (counts only), then drop and count it | S |
| F12 | buffer process heap reaches 9 MB of garbage under a flood (live state: 1 issue) | 08-27 flake | P2 | `Process.flag(:fullsweep_after, 20)` or hibernate after a flush; assert on it | S |
| F13 | the `ON CONFLICT ... count = count + EXCLUDED.count` upsert is exact under 8 concurrent writers | 08-25 | P1 | keep it; sort rows by fingerprint to avoid deadlocks between nodes | S |
| F14 | caller crumbs through `process_info(pid, {:dictionary, key})` copy one key only | 08-21 | P1 | use it for `$callers` (Task -> request); GenServer client via `client_info` next | S |
| F16 | `{:supervisor, :shutdown}` (max restart intensity) has no `crash_reason` meta and looks like a plain log | 08-36 | P1 | one clause: capture it as `exit <reason>` of the supervisor | S |
| F17 | Sentry builds events in the crashing process with blocking I/O (52..62 us, 50 ms+ when slow, per 01); the spike's caller cost is 33..40 us and independent of the backend | 08-33, 08-30, 01 | P0 | keep all I/O and formatting out of the caller | S |
| F15 | the `:atomics` in-flight cap was never reached by real load, only by a suspended buffer | 08-18, 08-32 | P2 | keep it as the last-resort bound; export the dropped counter in the UI | S |

## Recommendations for the lib

1. **Take the spike's pipeline shape as is**: handler in the caller -> `:atomics`-capped `send` ->
   one aggregating GenServer -> one writer Task at a time (`async_nolink`, timeout kill) -> Postgres
   upsert. Every property it needs was proven in 08-14..08-18 and 08-27..08-32; it is ~200 lines.
2. **Aggregate before storing**: the buffer keeps `fingerprint -> count, first_at, last_at, <= 3
   samples`; the DB gets one row per fingerprint per tick. This is why floods cost nothing (F8)
   and why a DB outage costs no memory (F9). Store all counts, sample the occurrences.
3. **Do only cheap things in the failing process**: fingerprint on raw frames with a cached
   stdlib set, read the pdict and label, then send. Format stacks, crumbs and `inspect` state in
   the buffer, only for kept samples (F6). Budget: <= 20 µs per `Logger.error`, <= 50 µs per crash.
4. **Breadcrumbs: a pdict ring of raw terms** (`{count, list}`, trim at 2x cap), fed by
   `Logger` below `:error` (the handler runs in the caller) plus a `Blackbox.crumb/1` API; read
   the caller's ring for Tasks through `$callers` (F14). Agree with agent 06 on caps and the
   debug-level question (06 found debug crumbs must be opt-in when the primary level is `:info`).
5. **Dedupe in the pdict, not in shared state** (not Sentry's whole-event hash, which misses PlugCapture+logger twins and silently drops repeats for 30 s, per 01): last `{fingerprint, message}` + 1 s window per
   process; plus the supervisor rule: drop `child_terminated` when the child reported an
   exception, keep it (as `exit <reason>`) otherwise, because it is the only witness of `:kill` (F5).
6. **Ship SASL as an opt-in switch that swaps the primary translator filter** (`sasl: true`), not
   via `Logger.configure`, which does nothing at runtime (F1). With the rule in 5 it adds brutal
   kills, plain `:proc_lib` crashes and supervisor give-ups (08-36) without duplicates. Also document that the default console
   handler will then print those reports too.
7. **Mark the tracker's own processes with logger metadata** and ignore it first in `log/2` (F10).
   Wrap both handlers in `catch _, _` plus a counter, because OTP detaches a crashing logger
   handler and `:telemetry` detaches a crashing telemetry handler.
8. **Fingerprint v1**: `sha256(kind, type, top 3 non-stdlib {module, function-with-fun-index-
   stripped, arity})`; logs masked (numbers, pids, refs, uuids); exits by shape. Never use
   `meta.mfa`, file or line (F3). Keep the version in the row so v2 can regroup.
9. **Writer failure policy**: merge back, backoff 50 ms..5 s, and add poison protection (F11):
   after 3 consecutive failures, write counts without samples; after 6, drop the batch and count it.
10. **Expose the counters** (`captured`, `dropped`, `handler_errors`, `writer_failures`, in flight)
    in the UI and the agent API: a tracker must show when it itself loses data.
11. **Keep these tests as the lib's safety suite**: 08-14..08-18, 08-27..08-32 and 08-31 (the
    tick without `flush/0`) are the regression net for "never takes the app down".
12. **Schema to start with**: `issues(fingerprint unique, type, title, count, first_seen,
    last_seen, status)` + `occurrences(issue_id, payload jsonb, inserted_at)`; retention trims
    occurrences per issue (keep last N), never the issue row.

## Sources

- Verified (ran): everything in the claims table; raw output in `logs/08-run-*.log`,
  `logs/08-flood.log`, `logs/08-probe-*.log`. Lab code: `lab/08-spike/` (Elixir 1.20.4, OTP 28 with
  erts-16.4.0.6, kernel-10.6.3.4, stdlib-7.3.0.2, tools-4.1.4.1; ecto_sql 3.x, postgrex, telemetry 1.x;
  PostgreSQL 18.6 via Postgres.app; Apple M3 Pro, `sysctl -n machdep.cpu.brand_string`).
- Read: `:logger.get_primary_config()` output (the `logger_translator` filter with `sasl: false`),
  `logs/08-probe-shapes.log`; `Logger.Translator.translate/4` returns `:skip` for an unknown label
  (`logs/08-probe-poison.log`); `erlang:process_info/2` item `{dictionary, Key}` (OTP 26+, erlang.org
  `erlang#process_info/2`); `:proc_lib.get_label/1` (OTP 27+).
- Peers: agent 01 `01-sentry.md` summary (logger handler off by default, whole-event dedupe, 30 s silent window, in-process cost, #933), relayed by the lead, which led to E4 and tests 08-36/37; agent 04 `04-beam-surface-lab.md` E2 (SASL on = 4 events per supervised crash, brutal kill
  visible only as `child_terminated`), which led to tests 08-34/35; agent 06 `06-before-lab.md`
  06-8, 06-9, F1, F2, F17 (pdict ring, dropped proc_lib report, 11 µs cross-process read), which
  match 08-19..08-23 and F1.
