### E4. The silent failures and OTP 27+ trace sessions (tests 04-40 .. 04-53, `test/d_trace_test.exs`, `test/e_trace_cost_test.exs`) — verified

First run: 04-40, 44, 46, 48, 49 green; 04-43, 45, 47, 50, 51, 52 red (details in the claims table).
Numbers in `logs/04-cost.log` (Apple M3 Pro, OTP 28, JIT, 11 schedulers).

- **Rescued-and-swallowed exceptions, `{:error, _}` returns and `catch :exit` reach no logger handler
  and no telemetry event.** The only BEAM mechanism that can see them without code changes is tracing.
- **`:trace` sessions (OTP 27+)** — `:trace.session_create(name, tracer, [])`, `:trace.function/4`,
  `:trace.process/4`, `:trace.session_destroy/1` — are isolated: two sessions trace one process
  independently and destroying one does not disturb the other (04-48). So the lib can own a session
  without fighting `:dbg`, `recon_trace` or a developer's session. (Pre-27 there was one global tracer
  per process.)
- **What each pattern sees**:
  - `exception_trace` on a module: sees an exception leaving a function (`:exception_from`) even when a
    caller rescues it. Does **not** see raise+rescue inside one function (04-44).
  - call trace on `{:erlang, :error | :exit | :throw, :_}`: sees every *explicit* raise/throw/exit
    call — including those rescued in the same function and BIF errors that OTP raises through
    Erlang-level wrappers (`atom_to_binary/1` calls `erlang:error/3`). It does **not** see errors raised
    by VM instructions: `badarith`, `badmatch`, `case_clause`, `element/2` badarg (04-45). And
    exits are noisy: a `GenServer.call` to a dead pid calls `exit/1` twice (04-47).
  - `return_trace` on a function shows `{:error, _}` returns, but the match spec runs at call time,
    so every return is sent and the tracer must filter (04-46).
  - Patterns only bind to **loaded** modules; a module loaded later stays untraced (04-49). In
    interactive mode (dev, `mix test`) modules load lazily, so a wildcard set at boot misses code.
    Releases (embedded mode) preload everything.
  - `silent` mode cannot be used to keep only exceptions: it suppresses `exception_from` as well (04-50).
- **Costs** (median of 3, ns per loop iteration of two tiny local calls):
  | setup | ns/iter | vs baseline | messages |
  |---|---:|---:|---:|
  | no pattern | 2.6-3.1 | 1x | 0 |
  | `{Silent,_,_}` exception_trace, *other* process traced | 13.6-14.8 | ~4.5x for **every** process calling those functions | 0 |
  | same, this process traced | ~16,000 | ~5,000x | 4 per iteration |
  | `{_,_,_}` on all 23,590 loaded functions, not traced | 13.9-14.8 | ~4.5x everywhere | 0 |
  | `{:erlang, :error/:exit/:throw, _}` call trace, traced | 2.6-3.4 | ~1x (noise) | 0 |
  | 100k swallowed raises, no trace | 58-70 ns/raise | | |
  | 100k swallowed raises, `erlang:error` traced | 410-430 ns/raise | +0.35 µs/raise | 1 per raise |

  Setting `{_,_,_}` takes 6-8 ms here (23,590 functions); a 1charta-sized release has several times more.
  **Verdict:** `exception_trace` is a debugging tool, never always-on. A call trace on
  `erlang:error/1,2,3` + `erlang:throw/1` (+ maybe `exit/1`) with `:trace.process(s, :all, true, [:call])`
  is cheap enough to be an **opt-in "swallowed exceptions" sampler**: zero cost on the happy path,
  ~0.35 µs + one message per raise; it needs a tracer process with its own overload protection
  (a raise flood becomes a message flood) and it misses instruction-raised errors. (Not measured: the
  `:all` process flag across many schedulers under load; agent 06/08 can.)
- Found by accident (04-53): **a raise costs O(stack depth)** — 0.07 µs in a tail loop, 48 µs inside a
  100k-deep body recursion (`for`/`Enum.map`). Cause unknown (not researched further); relevant for
  benchmarks of the lib's own `try` wrappers.

