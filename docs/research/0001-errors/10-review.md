# 10 Heavy-scrutiny review

Agent 10, 2026-09-27. Reviewed: ADR 0031, `index.html`, reports 01-08, labs 01/04/05/06/08 (all re-run), plus my own lab `lab/10-review/` (17 claim tests, 12 mutations). Machine: Apple M3 Pro, Elixir 1.20.4 / OTP 28.5. Git untouched.

## Verdict for the lead

The direction holds: the BEAM facts are real and re-run green, the pipeline's safety tests catch 9 of 12 mutations, and the primary-filter bet works (order holds, cost is noise, a raising filter is removed without taking logging down). The ADR is not ready to accept as written, because of three blockers:

1. **Blocker R-1: it contradicts itself on the handler level.** A `:notice` handler (2.3) never receives `:info` (10-12), so section 4's info crumbs through the handler cannot work. One-line fix: handler at the host's level, split in `log/2`.
2. **Blocker R-2: 1charta's privacy constraint is not met.** `format_status/1` covers `state` only, but `Board.Server`'s last message is `{:apply, ops, ...}` / `{:say, from, text}`. Exit reasons carry call messages as tuples, where no key-name scrubber looks. Exception messages embed values (Postgrex `Key (name)=(my-private-space)`, KeyError maps; 10-11). Crumbs are raw `GET /b/<id>` lines. `/tab/error` posts the board `key`.
3. **Blocker R-3: boot and shutdown lose the failures that matter most.** Blackbox starts after `Charta.Repo` (9.2), so "boot crashes wait in the buffer" (6) is false. Nothing flushes on shutdown, so the cascade before a `start_permanent` halt and each deploy's last batch die with the VM.

Serious:
- The decided SASL route has no end-to-end test (every spike test used the translator route), and the "console byte-identical" test does not exist (R-4).
- The dedupe drops real repeats uncounted (10-1, R-5). Cowboy's content key merges different requests (R-6).
- Log grouping splits per line on any letter id (10-2: about 20 000 issues from 20 000 lines, R-7).
- The seq_trace label leaks into the lib's own writer and DB pool (10-9a), and it has never been joined to a trail (R-8): defer it.
- Three fingerprint claims survive mutation: the fun-index strip, frame selection, and the ring bound (R-9, R-16).
- `/tab/error` makes "no public ingest" false for agents (R-10). Auth, CSRF and fence rules are unspecified (R-11).
- The writer shares the app's pool (R-12). The in-process "no formatting" rule was not what was measured (R-13).
- Wall-clock CI budgets will flake (R-14). Lab 05 was not green on my run: 05-43 is timing-dependent (R-17).

Minor: a mis-citation ("all red first"), "one row per fingerprint" (really 1 + 3), watchdog pause and give-up, stale line numbers, and page wording (sections 1a, 8).

Recommendation: fix R-1..R-3 in the text, and merge steps 1-2 around the existing spike with the missing tests. Defer the label, the system monitor, the crash-dump import, `escalating`, and the Cowboy, LiveView and Oban attachments until 1charta has used v1 (section 6).

## 1. Evidence vs ADR decisions

### 1a. Citation and number checks (read the tests and logs, not only the reports)

- **ADR "What the BEAM really sends", bullet 1: "(04-15, 04-27..29, 06-9, 08-7; all red first)".** Wrong: logs/04-claims.tsv marks 04-15, 04-27, 04-28, 04-29 **green** on the first run. Only 06-9 and 08-7 were red. The fact is right, the "all red first" is not.
- **The chosen SASL route (ADR 2.2, "route B": our own primary filter) has no end-to-end test.** 04-71/72/75/77 prove only that a spy filter placed first *sees* the reports (`BeamLab.PrimarySpy.filter/2` sends and returns `:ignore`, workers.ex:100-105). Every spike test that captures SASL reports (08-7, 08-34, 08-35, 08-36) uses **route A**: it removes and re-adds `:logger_translator` with `sasl: true` (capture_test.exs `sasl_filter/1`). So "one GenServer crash = one event", "a brutal kill = one `exit :killed` event", "a supervisor give-up is its own issue" are proven for route A only. With route B, the proc_lib report arrives in the *filter* and the gen_server report in the *handler*; the dedupe between those two call sites is untested.
- **"A test proves the console output is byte-identical" (ADR 2.2).** No such test exists in any lab. 04-77 asserts only `Enum.all?(handler, &(&1.meta[:domain] != [:otp, :sasl]))` on a capture handler; the spike's test_helper removes the `:default` handler (`:logger.remove_handler(:default)`), so no spike test sees the console at all. It is a promise for step 2, not evidence; the ADR words it as if it existed.
- **"The spike held (08) ... 10k to 200k Logger.error/s ... 0 dropped".** True as measured (my rerun: 08-27, 08-30 green; 08-32 in logs/08-flood.log: `sent == stored, dropped=0` at every rate), **but every flood uses one fingerprint**: `Logger.error("flood #{p} item #{i}")`, `"ramp #{p}"`, `"while db down #{p}"` (flood_test.exs, cost_test.exs:25) are all masked to the same template by `normalize_text/1` (digits -> `<n>`). The aggregating buffer turns a one-fingerprint flood into one map update per event; that is the easy case. A high-cardinality flood (a message that carries a non-numeric id) was never run. See 3f and my test 10-2.
- **"after 3 failures counts only, after 6 the batch is dropped and counted" (ADR 6).** Not in the spike: `Spike.Buffer.failed/2` merges back forever with backoff capped at 5 s (buffer.ex). Unproven design, cited under "as proven (08-14..18, 08-27..32)".
- **"Budget: ... a test fails the build over budget" and "33-40 µs per crash"**: measured by 08-33 on a stack of a few frames with a 20-crumb ring. The ADR's ring is 50 entries and `backtrace_depth` 32 (ADR 2.1): per-crash cost with 32 frames and a 50-crumb ring was not measured.
- **Fingerprint rule differs between spike and ADR.** ADR 5: "top 3 **in-app** frames ... in-app = modules of the host's own apps". Spike `Event.fingerprint/3`: top 3 frames **not in `[:elixir, :stdlib, :kernel, :logger, :telemetry, :erts]`**, i.e. dependency frames (Ecto, DBConnection, Phoenix, Plug, Jason) count. 08-9/10/11 prove line-shift and fun-index stability for the spike rule on a synthetic module with no deps in the stack; the ADR's in-app rule (and its fallback when no in-app frame is within `backtrace_depth`) is untested.
- **"Empty stack: label, registered name or initial call" (ADR 5).** Not implemented in the spike: `fingerprint(:exit, :killed, [])` hashes `[:exit, "exit :killed", []]`, so every kill of every child on the node is one issue (08-35 asserts only the type). 08-13 even asserts that two different timeouts with empty stacks share a fingerprint.
- **Dedupe: "every repeat is still counted" (08 summary item 7) is false for the spike's own code.** `Spike.Handler.capture_event/2`: when `seen?/1` matches it returns `:ok` with no `bump` and no push. A real second failure with the same fingerprint and message in the same process within 1 s is dropped silently, not counted. Proven by my test 10-1 below.
- **Test counts**: 01 27, 04 72, 05 65, 06 52 (+2 bench excluded, 54 declared), 08 40: all match the ADR table (verified by grep and by my runs).
- **05 green 3x: not reproduced.** My full-suite run had 05-43 red (see 2a).
- **Line references (read, HEAD 45107bb + working tree):** `board/server.ex:441, 482` and `notes.ex:935` correct; `spaces.ex:846, 1095` are the `rescue` lines, the `Postgrex.Error -> {:error, :taken}` clauses are at 847 and 1096; `participants.ex:125` -> the `unique_violation` check is at 127; `board.js:5921-5948` matches neither HEAD (`fetch("/tab/error"` at 5874) nor the working tree (5904) of `priv/static/assets/board.js`; `deps/hologram/lib/hologram/controller.ex:355` (`command_result = module.command(name, params, ...)`, Hologram 0.11.1) correct. Nits, but agents will follow these line numbers.


## 2. Lab re-runs and mutation checks

### 2a. Lab re-runs (verified, 2026-09-27 11:48-11:51, Apple M3 Pro, Elixir 1.20.4 / OTP 28.5)

Sequential, one lab at a time, nothing else of mine running (logs/10-rerun.log, logs/10-rerun-<lab>.log):

| lab | command | result | note |
|---|---|---|---|
| 01-sentry | `mix test` | 27 passed | matches ADR (27) |
| 04-beam | `mix test` | 72 passed, 49.4 s | matches ADR (72) |
| 05-frameworks | `mix test` | **64/65, 1 failure: 05-43** | FLAKY. `f_ecto_test.exs:118` expects `%Postgrex.Error{code: :query_canceled}`, got `%DBConnection.ConnectionError{reason: :closed}` (pool closed the socket first). Alone, 5/5 green (logs/10-rerun-05-ecto-x5.log): a race that shows under full-suite load. The ADR's "every suite green three runs in a row" is not true for 05 on my run. |
| 06-before | `mix test` | 52 passed, 2 excluded (bench) | 54 `test` declarations; 52 = ADR's count without benches, fine |
| 08-spike | `MIX_ENV=test mix test --include flood` | 40 passed, 58.1 s | 08-27 flood p99 32 µs, 08-30 DB down: 30000 sent, 30000 stored, writer_failures=5 |

### 2b. My own claims lab: `lab/10-review/` (a copy of `lab/08-spike`, DB `lab_0031_10`)

Protocol as in the BRIEF: each test was written with the assertion I believed before its first run. Files:
`lab/10-review/test/review/review_test.exs`, `fp_more_test.exs`, `logger_restart_test.exs` (run alone). Raw output:
`logs/10-lab-run1.log`, `logs/10-lab-run2.log`, `logs/10-lab.log`.

| id | claim (my belief) | first run | truth |
|---|---|---|---|
| 10-1 | the pdict dedupe drops, and does not count, a real 2nd failure with the same fingerprint+message in one long-lived process (two telemetry exception events 10 ms apart) | green | true: `counts=[1]` for two real failures. The 08 summary's "every repeat is still counted" is false. It bites wherever one process reports twice in 1 s: `capture_exception` in a GenServer's rescue (ADR 9.7 puts it in `Board.Server`), long-lived processes emitting exception telemetry. |
| 10-2 | a Logger.error flood whose messages carry a letters-only id (digits are masked, letters are not) makes one issue per message and overruns the buffer | green | true for the split, flaky for the overrun: 20 000 sent in 2 s, **19 926 to 20 000 issues written**; dropped 0 to 180 over six runs (at 10k/s a 100 ms tick holds ~1 000 new fingerprints, exactly the `@max_fingerprints` cap) (the drop assertion was removed as timing-dependent; logs/10-lab-run3.log). The one-fingerprint floods of 08 never exercised this. Every distinct fingerprint also pays `finish/1` (08-33: 215-247 µs per sample) in the single buffer process. |
| 10-3 | two app call sites failing inside Ecto share a fingerprint | green, **for the wrong reason** | the collision came from **tail calls**: `def run, do: Repo.query!(...)` leaves no `SiteA` frame (top frames `[Ecto.Adapters.SQL, Review.Test, Review.Test, ...]`); the test's own frames decided |
| 10-3b | same Ecto failure from two NON-tail call sites: two fingerprints | green | true: `[{Ecto.Adapters.SQL, :raise_sql_call_error}, {SiteC, :run}, ...]`; only one dep frame on top |
| 10-3c | Jason encode error from two non-tail sites shares a fingerprint (>= 3 Jason frames) | **red** | false: Jason re-raises from `Jason.encode!`, one dep frame. My worry that dep frames swamp the top 3 is **not** supported for Ecto or Jason. |
| 10-3d | tail-called `Map.fetch!` erases the app frame | **red** | false: the BIF error keeps `SiteG`. Only a tail call into a *remote function that raises* erases the caller. |
| 10-5 | a raising primary filter is removed; the event still reaches handlers | green | true (`logger_backend.erl` `handle_filter_failed/4` returns `ignore`); the removal is printed by `logger:internal_log` as `Logger - error: {removed_failing_filter,review_bad}` on stdout, **not** sent to handlers: our handler cannot see its own filter die. The watchdog is the only witness. |
| 10-6 | `Application.stop(:logger)` + `start` removes our prepended filter | green | true: before `[:review_first, :logger_translator, :logger_process_level]`, after `[:logger_translator, :logger_process_level]` (`Logger.App.stop/1` -> `redo(revert)` restores the pre-Logger primary config). The watchdog must re-add it; 5 s of SASL blindness. |
| 10-7 | `Logger.add_translator/1` (Plug.Cowboy calls it at boot) keeps a prepended filter ahead of the translator | green | true: `update_translators/1` re-appends `:logger_translator` at the end (`logger.ex:989`), result `[:review_first, :logger_process_level, :logger_translator]` |
| 10-8 | a domain-match primary filter costs < 0.3 µs per event | green | true: 0.67 vs 0.64 µs per `Logger.debug` (noise). The "runs on every log event" cost is not a concern. |
| 10-9a | a seq_trace label on the failing process reaches the lib's writer Task when the flush is a labelled call | green | true: writer saw `{:label, 4242}`. The lib's buffer and writer (and, through the writer's Repo calls, DBConnection's processes) adopt request labels. |
| 10-9b | through the 100 ms tick only, the writer has no label | green | true: an untokened `:tick` clears the buffer's token. So leakage depends on message order: not deterministic. |
| 10-10 | a crumb holding a 100-byte slice keeps a 4 MB binary alive | green | true: after GC the process still references `[4000000]`. The "4.4 KB for 50 crumbs" figure counts heap words only; raw terms can pin refc binaries of any size for the life of a process that never crashes. |
| 10-11 | exception messages embed secrets a key-name scrubber never sees | green | true: Postgrex `unique_violation` message ends `Key (name)=(my-private-space) already exists.`; `KeyError` message contains `%{token: "ck_live_SECRET"}` |
| 10-12 | a `:logger` handler at level `:notice` never receives `:info` | green | true (warning arrives, info does not). ADR 2.3 (handler at `:notice`) and ADR 4 ("Logger events at `:info` and up, through the handler") contradict each other. |
| 10-15 | a one-fingerprint flood writes up to 3 occurrence rows per 100 ms tick | green | true: 20 000 errors in 2 s -> 1 issue row, **63 occurrence rows**. "Floods cost one row per fingerprint per 100 ms" (ADR 6, Consequences) is really 1 upsert + up to 3 jsonb inserts per fingerprint per tick. |

Final: 17 tests (with 10-16 below); 15 green on first run, 2 red (10-3c, 10-3d: my beliefs were wrong). Their assertions were flipped to the observed truth; `mix test test/review/review_test.exs test/review/fp_more_test.exs` is green, 15 passed, seed 90807 (logs/10-lab-run3.log), after the 10-2 drop assertion was removed as timing-dependent; 10-6 runs alone (green). DB `lab_0031_10` is left in place so the suite can be re-run.

### 2c. Mutation checks on the spike's tests (verified; `lab/10-review/mutate.py`, logs/10-mutations.log)

Each mutation breaks one claimed behaviour in my copy of the spike's `lib/`, runs the spike test file(s) that claim it, then restores the file from `lab/08-spike`.

| mutation | tests run | result | verdict |
|---|---|---|---|
| M1 dedupe `seen?` always false | capture_test | 4 red (08-5, 08-7, 08-34, 08-36) | tests guard dedupe |
| M9 dedupe window 0 ms | capture_test | 4 red | guarded |
| **M2 anonymous-fun index NOT stripped** | fingerprint_test | **all green** | **08-10 passes on broken code.** Its extra `fn` sits in `run/1`, the raising fn in `step/1`; fun indexes are counted per enclosing function, so the raising fn keeps `-fun-0-` anyway. The claim "survives a new anonymous function" is unproven for the case that matters (a new fn in the same function, before the raising one). |
| M3 in-flight cap x1000 | pipeline_test | 08-18 red | guarded |
| M4 `child_terminated` rule off | capture_test | 3 red (08-34, 08-35, 08-36) | guarded (route A only, see 1a) |
| M5 writer's own logs not skipped | pipeline_test | 2 red (08-14, 08-16) | guarded |
| M6 upsert overwrites count | store_test | 2 red (08-24, 08-25) | guarded |
| **M7 crumb ring never trimmed** | crumbs_test | **all green** | the ring's memory bound (the "4.4 KB" / "trimmed at 100" claims) has no test; reads take 20 so every test still passes with an unbounded ring |
| M8 failed batch not merged back | pipeline_test | 3 red | guarded |
| M10 line number in fingerprint | fingerprint_test | 2 red (08-9, 08-10) | guarded |
| **M11 no stdlib/elixir frame skip at all** | fingerprint + capture | **all 19 green** | the frame-selection rule (the part the ADR changes to "in-app") has no test |
| M12 exit shape = whole reason | fingerprint + capture | 3 red | guarded |

Net: 9 of 12 mutations caught. The three that survive are exactly the grouping and memory claims the ADR leans on (fun-index stability, frame selection, ring bound).

Added later: **10-16** (`depth_test.exs`), belief "raise+rescue 40 frames deep costs < 0.5 µs more at `backtrace_depth` 32 than at 8": green, 47.47 vs 47.58 µs per raise (logs/10-lab.log). ADR 2.1's global flag is cheap. (The 47 µs absolute is odd for a raise; I did not chase it; the delta is what matters.)

## 3. The central technical bets, attacked

**(a) Our primary filter before the translator.** Holds, with two holes.
- Order: `logger_server.erl:391-399` `do_add_filter` prepends (`[Filter|Filters]`); verified by 04-71 and my 10-7: `Logger.add_translator/1` (Plug.Cowboy calls it at boot) *re-appends* `:logger_translator` (`elixir/lib/logger/lib/logger.ex:981-990`), so ours stays first. Releases: Blackbox's app starts after `:logger`, so ours is added after the translator and lands first. Fine.
- **Logger app restart removes it** (10-6, green): `Logger.App.stop/1` calls `redo(revert)` which restores the primary config from before Logger started (`logger/app.ex:70, 90-98`), so our filter is gone, not just reordered. The watchdog covers it with up to 5 s of blindness. Say so in the ADR.
- **A raising filter** is removed by `logger_backend.erl:122-137` (`handle_filter_failed/4` returns `ignore`, the event goes on), logging does not stop, and the only notice is `logger:internal_log(error, {removed_failing_filter, Id})` on stdout, which **no handler receives** (10-5: printed as `Logger - error: {removed_failing_filter,review_bad}`). Also: the removal is a `gen_server:call` into `logger_server` from the logging process. Wrap the filter body in `try` exactly like the handler.
- **Cost** per event is noise (10-8: 0.64 vs 0.67 µs per `Logger.debug`). The "runs on every log event" worry in Consequences is fine.
- **Hole: the translator stops more than `[:otp, :sasl]`.** `Logger.Utils.translator/2` (`logger/utils.ex:11-14`) also stops `[:supervisor_report | _]` domains and any report a translator answers `:skip` for; 08-17b (red first) proved a report with an unknown `label` is dropped for every handler. ADR 2.2's filter matches only `[:otp, :sasl]`, so it misses those. Either match `level >= :error` reports too (cheap: one `:logger.compare_levels/2`) or say the gap.

**(b) Work inside the dying or calling process.** The ADR says "No I/O, no calls, no formatting" in the failing process; the spike does formatting there: `Spike.Event.build/5` calls `inspect` on `last_message`, `state`, pid, callers and label, and `Exception.message/1`, and `from_log` runs three regexes over every `Logger.error` text (`normalize_text/1`). That is why a plain `Logger.error` costs 12.6-14.9 µs with the handler vs 0.62 without (logs/08-flood.log 08-33). With a real `Charta.Board.Server` state (a whole board) `inspect(limit: 20)` and the ADR's scrub-then-`:erts_debug.flat_size` walk are O(state size) in the dying process: **never measured on a big state**. The 50 µs "test fails the build" budget is a wall-clock assert; 08-33 already went red twice on a shared machine ("24 µs with_h on a machine shared with 7 other agents", cost_test.exs comment) and its bounds were loosened to "observed x2". A CI gate on wall time will flake; count reductions (`Process.info(self(), :reductions)` delta) instead, which is deterministic. Killed-while-reporting: a `:kill` during the handler loses the event silently (no counter can see it); a process near `max_heap_size` (1charta's SSE processes have `sse_max_heap_size_words: 32_000_000`, config/config.exs:21) copies its caller's ring into its own heap during the join: unmeasured, probably harmless.

**(c) The pdict crumb ring.** 42 ns and 4.4 KB are real for small terms (06-6/7). Not covered:
- **Raw terms pin binaries** (10-10: a 100-byte slice kept a 4 MB binary alive after GC). "4.4 KB" counts heap words only.
- **Processes that never crash keep their ring forever**: at 50 x ~90 B that is 4.4 GB per million processes that ever logged at `:info` or ran a query. Phoenix channels and LiveViews hibernate; hibernation keeps the dictionary. For a hex package this needs a stated ceiling (smaller ring outside request/job context, or ring only where a context was set).
- **The bound itself is untested** (M7 survived: an untrimmed ring passes every spike test).
- **"Secrets never enter the ring" contradicts "a ring of raw terms, 42 ns"**: scrubbing a Logger message needs text work at add time (unmeasured) or it happens at read time, and then the unscrubbed crumbs sit in the process dictionary, which shows up in `Process.info/2`, `:sys.get_status`, observer and in proc_lib crash reports' `dictionary` field (printed on the console by anyone who turns on `handle_sasl_reports`). 1charta's own `[info]` lines are `GET /b/<id>` paths (07: 3,683 prod lines, all `[info]`), exactly what ADR 9.3 wants scrubbed.

**(d) seq_trace as request id.** 128 ns per call is fine; the semantics are not.
- **The lib's own processes adopt labels** (10-9a: the writer Task saw `{:label, 4242}`), and from the writer, through `Repo` calls, DBConnection's pool and connection processes; a DB disconnect logged there later carries a stranger's request id. Whether it leaks depends on which message arrived last (10-9b: the tick clears it). "Cleared in the lib's own processes" (ADR 4) cannot be done on the receiving side; the handler must clear its token around its own `send` (`old = :seq_trace.set_token([])`, send, restore).
- **A label is not a join.** 06-52 proves only that the crashed server can *read* `"req-9"`; nothing maps a label to the request's ring. For a live request you need label -> pid (shared state), for a dead one the unproven (e) ETS table. Making the label the request process's pid (labels may be any term) turns (d) into (b) for live requests, with no table.
- A process that got a label and then never receives an untokened message (a loop, a `Task` doing long work) keeps it indefinitely: misattribution to an old request. Labels cross distribution to other nodes. Any host code or tool using `seq_trace` (rare) is overwritten; the config switch exists, auto-detection does not.

**(e) The 1 s pdict dedupe.** Proven for twins (08-5, M1 and M9 go red). But it **drops real repeats uncounted** (10-1), contrary to the 08 summary. Bandit HTTP/1 closes a connection after an exception (`bandit/http1/handler.ex:31`, `{:error, _} -> {:close, state}`), so the request path is safe; the explicit API (`capture_exception` in a GenServer's rescue, ADR 9.7) and long-lived processes emitting exception telemetry are not. Fix: on a mark hit, bump the issue's count (or a `deduped` counter) instead of returning. **Cowboy's content key has the mirror problem**: `phash2({kind, reason, stack})` is identical for the same bug in *different* requests, so under a flood the 2 s ETS key merges distinct failures (read from 05-60/61 and the key's definition; not run). Pair sightings (count down) instead of suppressing.

**(f) Aggregate before store, 3 samples.** Counts are exact and "0 dropped" is a measured, counted zero (08-27/32 check `sent == stored + dropped` against Postgres; my rerun agrees) **for one fingerprint**. Lost by design: every sample after the first 3 per fingerprint per 100 ms (first-3 bias: the samples all come from the start of a burst), per-occurrence request ids, users, builds and nodes within a batch, and precise times (`Store.write/2` sets `first_seen` and `last_seen` to the write time `now`, not the samples' `at`). High cardinality: 10-2 wrote 19 820-20 000 issues for 20 000 log lines in 2 s. Write amplification: 10-15, 1 upsert + ~3 jsonb inserts per fingerprint per tick (63 occurrence rows for 20 000 errors in 2 s).

**(g) Fingerprint v1.** Line shifts: guarded (M10 red). Fun index: **unproven** (M2 survives, 08-10 tests a fn in another function). Frame selection: **untested** (M11 survives). Tail calls erase the calling app frame when the call that raises is a remote tail call (10-3: `def run, do: Repo.query!(...)` leaves no `SiteA` frame), common in Elixir helpers; the next frame up then decides, and in generic code that merges sites. Deps swamping the top 3: **not supported** by my tests (10-3b/c: Ecto and Jason put one dep frame on top). Empty stacks: every `:killed` on the node is one issue (spike code; the ADR's label/name/initial-call fallback is not built). No in-app frame within `backtrace_depth` (a crash inside a Postgrex connection process): no rule. Log grouping masks digits, pids and uuids only; letters-only ids split per message (10-2). `grouping_version` is a column with no plan for regrouping old issues. Direct self-recursion collapses in the stack (04-34, second red): harmless for grouping.

**(h) Postgres in the same database.** The writer uses the host's `Repo` pool. When the failure *is* pool exhaustion (05-42), the tracker's checkout joins the queue of the starving app every 100 ms to 5 s; when the DB is down, the pool's own connection processes log errors that become events that are written through the same dead pool (08-30: "pending stays at 2 issues: the flood + Postgrex's own failed-to-connect log"). Bounded, but it adds load at the worst moment. Hot rows: one writer per node, fingerprints sorted (`store.ex`), so no deadlock between two nodes; the page's resolve/mute updates contend with the upsert on the same row, fine at 10 upserts/s. Proposal: a separate small pool (`pool_size: 1`, or a dynamic repo) for the writer, so the tracker never takes an app connection.

**(i) Scrubbing at capture.** Not complete, and 1charta leaks remain:
- Exception **messages** carry values: Postgrex `unique_violation` detail `Key (name)=(my-private-space) already exists.`, `KeyError` prints the whole map (10-11). A Space name is personal data; `spaces.ex:847/1096` rescue exactly this error.
- **Exit reasons and `last_message` are tuples**, not maps: `{:timeout, {GenServer, :call, [pid, {:apply, ops, by, base, signed}, 5000]}}` or `{:say, from, text}` (`board/server.ex:61, 162`) carry board content and chat text positionally; a key-name scrubber sees no key. The spike stores `short(reason)` as the message of every exit.
- **ADR 9.4 scopes `format_status/1` to state only.** OTP's `format_status/1` also receives `message` and `log`; 1charta must summarise all three, or the last message of a `Board.Server` crash is the ops with their text.
- `/tab/error` posts `key: B.key` in the body (`priv/static/assets/board.js`, `reportError`): `capture_browser/2` must never see the raw params.
- `Logger.warning("indexing board #{board.id} failed: #{Exception.message(e)}")` (`board/server.ex:482`, `notes.ex:935`): ids and nested exception text in the message; as crumbs they are raw (see c).
- FunctionClauseError args: the spike replaces them with the arity (good), while ADR 5 wants the top frame's arguments as "locals": raw structs, scrubbed only where they are maps with matching keys.
- Unknown: whether ADR 0021's sealed or browser keys ever sit in a server process's state or messages; I did not trace it.

**(j) Watchdog re-attaching.** Needed (10-5, 10-6). But: it fights an operator who removes the handler on purpose during an incident, and it loops if a bug makes a body raise before the `catch` (removed, re-added, raised, every 5 s, each announced). Add `Blackbox.pause/0` that the watchdog respects, and give up after N re-adds in a window with one event. Reordering primary filters is a read-modify-write of `:filters` that races `Logger.add_translator/1` (which runs under `:elixir_config.serial/1`; ours would not): a lost update is possible, rare.

**(k) Page and API.**
- **`authorize` has no stated default**: make it required (refuse to mount without it).
- **CSRF**: `POST resolve/mute/note` and the actions (watch, record 60 s, trace 30 s) are state-changing. In dev ("localhost only", no token) any web page the developer opens can POST to `http://localhost:4000/_blackbox/...`; how a human carries `BLACKBOX_TOKEN` in a browser in prod is unspecified (a cookie would need CSRF tokens; a query string would land in logs and crumbs). "Localhost only" by `remote_ip` does not stop DNS rebinding; check `Host` too.
- **XSS**: event text is attacker-influenced (browser errors, exception messages with user input); the page must escape everything, and 1charta's CSP for boards allows `'unsafe-inline'` (`endpoint.ex:91`), so the page should send its own strict CSP.
- **Markdown fences**: an event text containing a triple-backtick closes a plain fence. Use a fence longer than the longest backtick run in the text (CommonMark), or JSON-string the fields.
- **"No public ingest" is false once ADR 9.6 is wired**: `/tab/error` accepts text from anyone holding a board link (60 per board per minute), and that text reaches agents through `GET /issues/:id.md`. That is the VU#212479 shape. Mark `:browser` events as such in the Markdown, keep them out of the default agent view, or require the fence and a warning line.

## 4. Coverage honesty: is "ALL errors" oversold?

The Decision's own sentence is honest ("every failure it can see"), and Consequences names three ceilings (unsupervised exits, swallowed exceptions, burst drops). The Context headline and the page ("catches every failure the BEAM lets it see") are fair. What is still invisible and **not** said:

| failure class | visible? | ADR says so? |
|---|---|---|
| NIF segfault / abort | no: the OS kills the VM, **no `erl_crash.dump`** is written for a signal | no (2.6 implies the dump is "the witness" when the VM dies) |
| Linux/Docker OOM kill (SIGKILL) | no, and no dump | no |
| VM out of memory in an allocator | dump yes ("eheap_alloc: Cannot allocate"), header import in step 7 | yes (2.6) |
| `System.halt/1`, `:erlang.halt/1` from code | no event, no dump unless `halt(String)` | no |
| `start_permanent: true` top supervisor giving up (07: prod has it) | dump yes ("Kernel pid terminated"); **the events of the cascade that led there are in the buffer and die with the VM** unless flushed | no: nothing in section 6 flushes on shutdown or `prep_stop` |
| deploy SIGTERM with events in flight (last <= 100 ms, or all of it while the DB is backing off) | lost | no |
| port / driver errors (`{:EXIT, port, reason}` to an owner that traps) | no | no |
| exits trapped and ignored (`handle_info({:EXIT, ...})` doing nothing) | no (the linked process's own crash is seen if it was proc_lib) | no |
| `Task.async_stream(..., on_timeout: :kill_task)`, `Task.shutdown(t, :brutal_kill)` | no (a kill) | partly (kills of unsupervised processes) |
| distributed node down, net splits | no (1charta is one node) | no |
| `:alarm_handler` / os_mon alarms (disk, memory) | no: alarms go through `gen_event`, not `:logger`; os_mon is not started in 1charta | no |
| code loading, `on_load` failures | yes if logged at error by `code_server`; `:undef` crashes yes | not needed |
| reports with an unknown label, `[:supervisor_report]` domain | no (translator stops them, 08-17b) | no (see 3a) |
| crashes before `Blackbox` starts | no: ADR 9.2 starts it **after `Charta.Repo`**, so a Repo or Telemetry crash at boot has no handler and no buffer; ADR 6 "Before the Repo is up, events wait in the buffer" is wrong for this wiring | contradicts itself |
| tracker's own boot | the lib's own events carry `[:blackbox]` and are dropped first (6); a Blackbox start failure takes down `Charta.Application`? unknown: child spec restart type not specified | no |
| browser errors off boards (Space and note pages) | no: only `board.js` has `window.addEventListener("error")`; `note.mjs`, `space.html`, `editor.mjs` report nothing | no (9.6 wires `/tab/error` only) |
| Hologram client action errors | only where the page's JS reports them (boards) | partly (07: actions run in the browser) |
| LiveView client (JS) errors | no (server crash yes) | no, fine for 1charta |
| `plug_status < 500` exceptions, `:normal`/`:shutdown` exits | counted, not issues | yes |
| rescued exceptions, `{:error, _}` | only with the 30 s trace or explicit API | yes |
| burst of plain spawn crashes | partly, VM drops | yes |

Fix cheaply: start Blackbox's capture (handler, filter, buffer) from **its own OTP application** (a path dep is an app that boots before `:charta`), attach the store when the Repo is up; flush the buffer in `terminate/2` with `trap_exit` (children stop in reverse order, so it stops before the Repo); name the NIF/OOM/halt ceiling in Consequences.

## 5. Contradictions between reports, and how the ADR resolved them

| contradiction | reports | ADR | verdict |
|---|---|---|---|
| context store: 05 rec. "keep request/job context in ETS by pid, walk callers" (05 summary 6) vs 06 "ETS ring leaked 59 MB, pdict ring" | 05, 06 | pdict ring + `$callers` read of the parent's dictionary; ETS only for Cowboy dedupe and (e) | resolved, implicitly; ADR 10 "no ETS crumb store" and 4(e) "one ETS table of trails" should say why (e) is not the rejected design: bounded by count (200) and time (10 s), written only at request stop. The per-request cost of that write (a 50-crumb trail copied into ETS on **every** request, not only on failure) is not measured and not in the "+5 µs p50". |
| Cowboy key TTL: 05 "5 s TTL" vs ADR "2 s" | 05, ADR | 2 s, no reason | unresolved nit |
| burst drops (04-68: 1,665-4,799 of 10k) vs "0 dropped" (08-29) | 04, 08 | both stated: burst vs paced | resolved correctly; the page's table row cites 08-29 for the burst loss (index.html row "burst of plain spawn crashes ... 04-68, 08-29"), which is the paced test where all arrive: mis-citation |
| drop-mode notices: "an uncounted `:notice`" (04 summary 9, ADR) vs "two `:notice` events" (04 body, 04-68 row, page) | 04, page | ADR says one | nit, pick one |
| handler level `:notice` (ADR 2.3) vs "Logger events at `:info` and up, through the handler" as crumbs (ADR 4) | ADR vs itself | **unresolved: they cannot both hold** (10-12). The spike's handler is `level: :all` and splits in `log/2`. |
| "Warnings and infos become crumbs" with a `:notice` handler | ADR 2.3 | infos never arrive; warnings are above notice so they do | same as above |
| debug crumbs opt-in per module via `Logger.put_module_level/2` (ADR 4) vs 06-2 "every other handler must then carry its own level" | 06, ADR | not mentioned | unresolved: a module opened to `:debug` prints its debug lines on the console (Elixir's default handler has no level of its own) unless the lib sets the console handler's level; that is a setting change the user sees, which 2.2 promised not to do |
| ring size: spike 20 (trim at 40), 06 50 (trim at 100), ADR 50 | 06, 08 | 50 | resolved; but 08's 33-40 µs per crash was measured with 20 crumbs and 12 frames, ADR sets 50 and depth 32 |
| dedupe key: spike `{fingerprint, message}` single slot vs ADR `{fingerprint, reason hash}` | 08, ADR | ADR's | fine, but single-slot vs set is unspecified (A, B, A in 1 s reports A twice with one slot) |
| "no formatting in the failing process" (ADR 6) vs the spike's `inspect`/regex in `build/5` | 08, ADR | ADR wins on paper | the measured 33-40 µs and 12.6-14.9 µs include that formatting; removing it is unmeasured |
| SASL route: 04 recommends route B (own primary filter); 08 tested only route A | 04, 08 | route B | chosen without an end-to-end test (1a) |
| "every repeat is still counted" (08 summary 7) vs spike code | 08 | repeated on the page ("Every repeat counted") | false (10-1) |

## 6. Over-engineering and scope (ponytail lens)

The ADR is large for a personal tool's v1 (seven steps, six hooks, a label protocol, three on-demand tracers, states with baselines, a store behaviour). What 1charta needs to beat Sentry today is small: **every crash, once, with its trail and its last message/state, in its own Postgres, one page, one `.md` per issue.** Rank:

- **Keep for v1**: the handler (at `:info`, splitting in `log/2`), the primary filter (route B, try-wrapped), Phoenix/Bandit/`[:telemetry, :handler, :failure]` telemetry, the pdict ring with the per-request reset, `$callers` and `client_info` joins, fingerprint v1 with tests for the three survived mutations, the aggregating buffer with in-flight cap, two tables with upsert, scrubbing (with `format_status/1` over `state`, `message` and `log` in 1charta), the inbox and issue page, `GET /issues/:id.md`, `current_ref`, the watchdog (10-5/10-6 prove it is needed).
- **Defer** (no 1charta need measured): the seq_trace label and the (e) trail table (unproven, leaks into the lib, 10-9a); the OTP 28 system-monitor session; the crash-dump import (config `ERL_CRASH_DUMP` now, import when a dump actually shows up; 07: the only one was from `mix test`); `escalating` with hourly baselines and the `on_issue` callback (1charta does "nothing yet" with it); Cowboy's ETS fallback, LiveView, Oban and Cowboy telemetry (1charta runs none; attach when a user does, with the lab 05 fixtures ready); `Blackbox.Store` behaviour + in-memory store (test against the lab DB like the spike did, or keep only if the hex package needs it); dev files `tmp/blackbox/*.md` (agents can `curl` the `.md` route); the three on-demand tracers and `watch/1` (step 7 already, fine as last).
- **Simplify**: "four hooks" names six items; say "one install". The 5-state machine can start as `open | resolved(build) | muted`, with `regressed` derived at read time (new occurrence with a later build than the resolve).
- **Missing from a minimal v1**: flush on shutdown; start capture from the lib's own application; a separate 1-connection pool for the writer; a count for deduped sightings; high-cardinality log grouping (mask any token with a digit or 8+ random-looking chars, or group logs by call site `mfa`+`line` from Logger metadata instead of text; Logger metadata has `file`, `line`, `mfa` for Elixir `Logger` calls, see 05-14 keys).

Proposed smaller steps 1-2 (replacing ADR steps 1-4 as the first delivery): **(1)** skeleton + capture + normalizer + fingerprint + buffer + Postgres store in one step, ported from the spike (it already exists, 440 lines), with the three missing tests (fun index in the same function, frame selection, ring bound) and 10-1 fixed; **(2)** ring + joins + scrubbing + the page and `.md` API + 1charta wiring 9.1-9.7. Everything else after 1charta has lived with it for a few weeks.

## 7. 1charta specifics (read-only checks)

- Line refs: see 1a (two off by one, one stale: `board.js:5921-5948`; `participants.ex:125` is 127).
- Dockerfile: `COPY mix.exs mix.lock ./` (line 55) then `RUN mix deps.get --only $MIX_ENV` (56); a path dep needs `COPY packages packages` before 56: **correct**. Report 07's "path dep works with `mix release`" is marked read, not built; ADR step 1 checks it in CI, fine.
- Hologram: `controller.ex:355` `command_result = module.command(name, params, middleware_server_struct)` with no rescue around it (Hologram 0.11.1): **correct**. The "lib in Hologram's call graph" claim (07 F15, `reflection.ex:341-359`) is read, not tried; plausible and consistent with the memory notes on Hologram's call graph cache. ADR 9.8's "wrap `module.command/3`" has no hook in Hologram to wrap: 1charta would have to wrap each component's `command/3` (or put `set_context` in a Hologram middleware, since `Middleware.run/2` runs just before at line 340). Specify which.
- `config :phoenix, :filter_parameters, ["password", "key"]` (config/config.exs:43): `key` is already filtered; Phoenix matches by substring.
- Privacy: ADR 9.4 covers `state` only; see 3i for `message`/`log`, the posted `key` in `/tab/error`, and Postgrex detail text.
- The rescue-to-`:taken` bug (`spaces.ex:847, 1096`) is real as read; "fixed separately" is right.

## 8. Page (index.html) vs the final ADR

- "the console byte-identical" (hero list, line "Four hooks, one install") and "console byte-identical (04-71, 04-77)" (sentry comparison table): presented as proven; no test shows it (1a).
- "Repeats: Every repeat counted" (sentry comparison table): false for the spike (10-1).
- "Floods cost one row per fingerprint per 100 ms" (pipeline section): 1 upsert + up to 3 inserts (10-15).
- 08-27 row "buffer <= 3.0 MB": one final run reached 9.2 MB (cost_test/flood_test comment, 08 claims row 08-27); report 08's own summary says 0.2..9 MB.
- "burst of plain spawn crashes ... 04-68, 08-29": 08-29 is the paced test where all 30 000 arrive.
- "two :notice lines" vs the ADR's "one uncounted :notice".
- Otherwise the page matches the ADR (256/54, the lab table, the decisions, the 1charta list); I found no statement on the page that the final ADR contradicts beyond the above.

## Findings table

| id | severity | what | evidence | fix in one line |
|---|---|---|---|---|
| R-1 | blocker | Handler at `:notice` (2.3) cannot deliver the `:info` crumbs section 4 relies on; "warnings and infos become crumbs" is impossible as written | 10-12; OTP handler level semantics; spike handler is `level: :all` (handler.ex `attach/1`) | handler at `:info` (the host's level), `log/2` splits: `>= :error`, app exits and proxy notices -> events, the rest -> crumbs |
| R-2 | blocker | 1charta's privacy constraint is not met by the decided scrubbing: `format_status/1` scoped to `state` only (9.4) while `last_message` of `Board.Server` is `{:apply, ops, ...}`/`{:say, from, text}`; exit reasons carry call messages positionally; exception messages embed values (Postgrex detail, KeyError maps); crumbs are raw terms incl. `GET /b/<id>` paths; `/tab/error` posts `key` | 10-11; `board/server.ex:61, 162`; spike `message/2` = `short(reason)`; `board.js` `reportError`; 3c, 3i | 9.4: `format_status/1` summarises `state`, `message` and `log`; scrub crumbs at add time for Logger text (measure it) or never persist Logger text of `:info` crumbs in 1charta; cap and scrub exception messages (drop Postgrex `detail`); `capture_browser/2` takes only `{name, message, stack, url}` |
| R-3 | blocker | Boot and shutdown lose the failures that matter most: ADR 6 says boot crashes "wait in the buffer" but 9.2 starts Blackbox after `Charta.Repo` (no handler, no buffer before it); nothing flushes the buffer on shutdown, so a `start_permanent` halt's cascade and every deploy's last batch are lost | ADR 6 vs 9.2; 07 (`start_permanent: true`, SIGTERM 30 s grace); spike `Buffer` has no `terminate/2` | capture from the lib's own OTP app (boots before `:charta`), store attaches when the Repo is up; `trap_exit` + flush in `terminate/2`; state the NIF/OOM/halt ceiling |
| R-4 | serious | The chosen SASL route (own primary filter) has no end-to-end test; every spike SASL test used route A (translator `sasl: true`); "a test proves the console is byte-identical" does not exist | capture_test.exs `sasl_filter/1`; 04-77 asserts only domains; spike removes `:default` | step 2 starts with route B ports of 08-7/34/35/36 and a real console-capture test (`ExUnit.CaptureLog` or a std_h to a file, before/after byte compare) |
| R-5 | serious | Dedupe drops real repeats uncounted (single-slot pdict mark, 1 s) | 10-1; `handler.ex` `capture_event/2` | on a mark hit, count on the issue (or a `deduped` counter); key a set, not one slot |
| R-6 | serious | Cowboy content key `phash2({kind, reason, stack})` merges identical failures of different requests under a flood | 05-60/61 design, read; not run | pair sightings (count down per key) or include the request pid/stream from the Cowboy report |
| R-7 | serious | Log grouping splits on any non-digit id; floods were only ever one fingerprint | 10-2: 19 820-20 000 issues for 20 000 lines; all 08 floods use digit-only variation | group `:log` events by Logger `mfa`+`line` metadata when present, template masking as fallback; run 08-27/32 with a high-cardinality variant |
| R-8 | serious | seq_trace label leaks into the lib's buffer, writer and DB pool processes; the label is readable but never joined to a trail (06-52 proves reading only); (e) is unproven and costs a copy per request | 10-9a/b; i_join_test.exs 06-52; ADR 4(e) | defer the label to after v1; if kept, label = request pid, clear the token around the handler's own `send` |
| R-9 | serious | Fingerprint tests are weaker than the claims: fun-index strip and frame selection survive mutation; empty-stack fallback is unbuilt (all `:killed` = one issue); tail calls erase the app frame; no rule for "no in-app frame" | M2, M11 (logs/10-mutations.log); 10-3; `event.ex` `fingerprint/3` | add tests: new fn *in the same function*; frame rule (in-app vs deps); empty stack by label/name/initial call; zero in-app frames |
| R-10 | serious | "No public ingest" is false once `/tab/error` feeds Blackbox: anyone with a board link injects text that agents read via `.md` | ADR 8, 9.6; `tab_controller.ex:55-67` | mark `:browser` events untrusted in the Markdown header, exclude them from the default agent listing, keep the 60/min cap |
| R-11 | serious | Page/API security unspecified: `authorize` default, CSRF on POSTs and actions (dev has no token), DNS rebinding on "localhost only", HTML escaping, fence breaking by backticks | ADR 8; `endpoint.ex:91` board CSP has `'unsafe-inline'` | `authorize` required; POSTs need a header token (no cookie auth); `Host` check in dev; escape all text; fence longer than any backtick run; own strict CSP |
| R-12 | serious | Writer shares the app's Repo pool; during pool exhaustion or DB down it queues with the starving app and its failures feed new events | 05-42, 05-44; 08-30 ("pending 2 issues: the flood + Postgrex's own log") | separate 1-connection pool (second Repo or dynamic repo) for the writer |
| R-13 | serious | "No formatting in the failing process" is not what was measured: the spike `inspect`s state/last_message and runs 3 regexes per `Logger.error` in the caller (12.6-14.9 µs vs 0.62); big states unmeasured; scrub + `flat_size` is O(state) | `event.ex` `build/5`, `normalize_text/1`; logs/08-flood.log 08-33 | send the raw report (bounded by `format_status/1`) and do inspect/scrub in the buffer, or measure a 1 MB state in the dying process before deciding |
| R-14 | serious | Build-failing wall-clock budgets will flake in CI (08-33 went red twice on a shared machine; its bounds were loosened x2) | cost_test.exs comment at 08-33 | budget in reductions per capture, wall time only logged |
| R-15 | serious | Translator also stops `[:supervisor_report]` and unknown-label reports; the filter matches `[:otp, :sasl]` only | `logger/utils.ex:11-14`; 08-17b (red first) | filter also takes `level >= :error` reports, or name the gap |
| R-16 | serious | Ring memory: raw terms pin refc binaries; rings persist in never-crashing (and hibernated) processes; the bound is untested | 10-10; M7; 3c | copy/cap binaries at add (`:binary.copy` of slices > 64 B, or store only `byte_size`); ring only in processes with a request/job context by default; a test on the ring's `flat_size` |
| R-17 | serious | "Every suite green three runs in a row" not reproduced: 05-43 failed in my full run (pool closed the socket before `query_canceled`), green alone 5/5 | logs/10-rerun-05-frameworks.log, logs/10-rerun-05-ecto-x5.log | accept both `Postgrex.Error{query_canceled}` and `DBConnection.ConnectionError{reason: :closed}` |
| R-18 | minor | Unproven policies cited as proven: "after 3 failures counts only, after 6 dropped" is not in the spike | `buffer.ex` `failed/2` | mark as design, test in step 4 |
| R-19 | minor | "Floods cost one row per fingerprint per 100 ms": 1 upsert + up to 3 jsonb inserts | 10-15: 63 occurrences for 20 000 errors in 2 s | reword; the retention pruner must keep up with ~30 rows/s per hot fingerprint |
| R-20 | minor | Samples keep the first 3 per tick; `first_seen`/`last_seen` are write time, not sample time | `buffer.ex` `add/4`; `store.ex` `write/2` (`now`) | reservoir or first+last samples; use sample `at` |
| R-21 | minor | Watchdog fights an intentional removal and can loop on a deterministic raise; filter reorder races `Logger.add_translator/1` | 10-5, 10-6; `logger.ex:981-990` | `Blackbox.pause/0`; give up after N re-adds per window with one event |
| R-22 | minor | Logger app restart removes our filter entirely (5 s SASL blindness until the watchdog) | 10-6 | say it; optionally hook `Logger` app restart via the watchdog's 5 s check only |
| R-23 | minor | Debug crumbs per module print on the console unless the console handler gets its own level; that is a visible setting change | 06-2; ADR 4 | set the console handler level to the previous primary level when enabling, and document |
| R-24 | minor | Citation "(04-15, 04-27..29 ... all red first)" wrong: those four were green | logs/04-claims.tsv | drop "all red first" or cite 06-9, 08-7 only |
| R-25 | minor | 33-40 µs per crash measured with 12 frames and 20 crumbs; ADR sets depth 32 and 50 crumbs | cost_test.exs 08-33 | re-measure at the ADR's settings |
| R-26 | minor | Minimum OTP undeclared though ADR mentions "older OTP" paths (`process_info(pid, {:dictionary, k})`, `:trace` sessions, `trace:system/3` need 26.2/27/28) | ADR 2.5 | declare OTP >= 27 (or 28) for v1; drop the fallback |
| R-27 | nit | Line refs: `spaces.ex:846, 1095` -> 847, 1096; `participants.ex:125` -> 127; `board.js:5921-5948` -> 5874 (HEAD) / 5904 (tree) | grep, `git show HEAD:` | update |
| R-28 | nit | Page: "console byte-identical", "every repeat counted", "one row per fingerprint", "buffer <= 3.0 MB" (9.2 MB seen), 08-29 cited for burst loss, notice count | index.html; section 8 | edit the page with the ADR |
| R-29 | nit | "Four hooks, one install" lists six items; Cowboy TTL 2 s vs 05's 5 s without reason | ADR 2; 05 F3 | "one install"; state the TTL reason |
| R-30 | nit | Hologram has no hook to "wrap `module.command/3`" (9.8) | `controller.ex:340-355` | put `set_context` in a Hologram middleware, or a macro in 1charta's components |

## What held up

- The core facts of the BEAM surface: the translator hides SASL by default; a prepended primary filter sees it (04-71/72/75/77 green on my run); handlers run in the logging process; a raising handler is removed silently; a raising **filter** is removed and logging continues (10-5); `Logger.add_translator/1` keeps our filter first (10-7); filter cost is noise (10-8); `backtrace_depth` 32 is cheap (10-16).
- The pipeline: in-flight cap, merge-back of failed batches, writer kill, self-skip, upsert counts: mutations M3, M4, M5, M6, M8, M1, M9, M10, M12 all turn the spike's tests red. The DB-down test is real: 30 000 of 30 000 stored after recovery on my rerun.
- Counts are exact and "0 dropped" is a counted zero checked against Postgres (for one fingerprint).
- The sentry-elixir findings (01) re-ran green (27/27).
- Report 07's main 1charta claims (rescue sites, Hologram command site, Dockerfile order, crash dump origin as read) check out.
- The ADR is honest about the two big ceilings (unsupervised exits, swallowed exceptions) and about burst drops.

## Proposed ADR edits

- **Context, "What the BEAM really sends", bullet 1**: replace "(04-15, 04-27..29, 06-9, 08-7; all red first)" with "(04-15, 04-27..29; 06-9 and 08-7 red first)".
- **Context, bullet "The spike held"**: add "All floods used one fingerprint; a high-cardinality log flood splits into one issue per line (10-2). The spike's dedupe drops real repeats uncounted (10-1). Its SASL tests used the translator's `sasl: true` route, not the primary filter decided below."
- **2, intro**: "four hooks" -> "one install".
- **2.2**: append "The filter body is wrapped like the handler's; a raising filter is removed by OTP with only a stdout line (10-5), and a restart of Elixir's Logger app removes it (10-6): the watchdog re-adds it. Besides `[:otp, :sasl]` it takes `[:supervisor_report]` and every `:error` report, which the translator may also stop (08-17b)." Replace "A test proves the console output is byte-identical." with "Step 2 adds a test that proves the console output byte-identical."
- **2.3**: replace "One `:logger` handler, level `:notice`" with "One `:logger` handler at the host's primary level (`:info` by default); `log/2` makes events of `:error` and above, `{:application_controller, :exit}` at `:notice`, `removed_failing_handler` and proxy notices, and crumbs of the rest (10-12: a `:notice` handler never sees `:info`)."
- **3, Dedupe**: append "A mark hit adds to the issue's count; it never drops a count (10-1). Cowboy's content key pairs sightings (one telemetry, one log) instead of suppressing every equal failure for 2 s."
- **4, ring**: replace "Secrets never enter the ring" with "Logger text is scrubbed when it becomes a crumb (cost measured in step 3) or not kept; binaries in crumbs are copied if they are slices, capped at 200 bytes (10-10)."
- **4, request id**: move the `seq_trace` label and (e) to "Later", with "10-9a: the lib's own processes and the DB pool adopt the label; 06-52 proves reading, not joining."
- **5, Fingerprint v1**: add "Tests for: a new anonymous function in the same function; in-app vs dependency frames; an empty stack (label, registered name, initial call); no in-app frame (top 3 frames of any app). Logs group by `{mfa, line}` from Logger metadata when present."
- **6**: replace "Budget: 20 µs per `Logger.error`, 50 µs per crash; a test fails the build over budget" with "Budget in reductions per capture, asserted; wall time measured and logged, not asserted." Add "**Flush on stop**: the buffer traps exits and writes what it holds in `terminate/2`; capture starts from Blackbox's own application, before the host's tree." Replace "Before the Repo is up (boot crashes), events wait in the buffer" accordingly. Add "The writer uses its own one-connection pool."
- **6 / Consequences**: replace "Floods cost one row per fingerprint per 100 ms" with "Floods cost one upsert and at most three occurrence rows per fingerprint per 100 ms (10-15)."
- **8, Auth**: append "`authorize` is required. State-changing routes take the token in a header, never a cookie; dev checks `Host` as well as the peer. All event text is HTML-escaped; Markdown fences are longer than the longest backtick run in the text. Browser events are marked untrusted and left out of the default agent listing: `/tab/error` is an ingest anyone with a board link can write to."
- **9.4**: replace "(state summarised ...)" with "`format_status/1` summarises `state`, `message` and `log` (board id, op kinds and counts, tab count; never text, titles or chat)".
- **9.6**: append "`capture_browser/2` receives `{name, message, stack, url}` only, never the posted `key`."
- **9.8**: replace "wraps `module.command/3`" with "sets the context in a Hologram middleware (it runs just before `module.command/3`, `controller.ex:340`)".
- **Consequences**: add "Not seen at all: NIF crashes and OOM kills (no crash dump), `halt` from code, port exits to trapping owners, os_mon alarms, browser errors outside boards."
- **Steps**: merge steps 1-2 and move system monitor, crash-dump import, label, escalating, Cowboy/LiveView/Oban attachments, dev files and the store behaviour behind "after 1charta has used v1".
- **Context table**: footnote "05: 05-43 is timing-dependent under full-suite load (review 10)".

## Sources

- ADR: `docs/adr/0031-blackbox-every-failure-and-what-came-before.md` (read in full).
- Reports 04, 05, 06, 07, 08 (summaries, claims tables, cited sections), `logs/04-claims.tsv`, `logs/08-flood.log`, `index.html` (text extracted).
- Lab code read: `lab/04-beam/test/g_routes_test.exs`, `test/support/{case,workers}.ex`, `lib/beam_lab/capture.ex`; `lab/06-before/test/i_join_test.exs`, `lib/ring.ex`; `lab/08-spike/lib/**`, `test/{capture,fingerprint,pipeline,flood,cost}_test.exs`, `test/support/{sink,load}.ex`, `config/config.exs`, `test/test_helper.exs`.
- OTP 28.5.0.6 source (verified locally): `kernel-10.6.3.4/src/logger_backend.erl:28-137` (filter and handler failure), `logger_server.erl:391-399` (prepend).
- Elixir 1.20.4 source: `lib/logger/lib/logger/app.ex:40-110` (translator install, stop/revert), `lib/logger/lib/logger.ex:968-990` (`add_translator` re-appends), `lib/logger/lib/logger/utils.ex:11-55` (translator stops).
- Bandit 1.12.5 (lab 05 deps): `lib/bandit/pipeline.ex:201-245`, `lib/bandit/http1/handler.ex:31`.
- 1charta (read-only, HEAD 45107bb + working tree): `lib/charta/board/server.ex:59-200, 440-482`, `lib/charta/notes.ex:934-935`, `lib/charta/spaces.ex:846-847, 1095-1096`, `lib/charta/participants.ex:127`, `lib/charta_web/endpoint.ex:91`, `lib/charta_web/controllers/tab_controller.ex:55-67`, `priv/static/assets/board.js` (`reportError`), `config/config.exs:21, 43`, `Dockerfile:55-56`, `deps/hologram/lib/hologram/controller.ex:340-355` (Hologram 0.11.1).
- My runs (verified): `logs/10-rerun*.log`, `logs/10-lab-run{1,2,3}.log`, `logs/10-lab.log`, `logs/10-mutations.log`; lab `lab/10-review/` (tests in `test/review/`, `mutate.py`), DB `lab_0031_10`. Web searches used: 0.
