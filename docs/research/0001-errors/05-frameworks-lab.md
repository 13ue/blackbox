# 05 Frameworks lab: what Phoenix, Bandit, Cowboy, Plug, channels, LiveView, Ecto, Oban, Req and Hologram report when they fail

Agent 05, 2026-09-27. LAB. Status: done. Lab: `lab/05-frameworks/` (65 tests). Logs: `logs/05-frameworks.log`, `logs/05-run-*.log`.

## Summary for the lead

1. Neither hook alone sees everything. The `:logger` handler misses **every Oban failure** (Oban logs nothing by default) and every exception with `plug_status` < 500. Telemetry misses channels (no exception events exist), LiveView `handle_info`, Tasks, DBConnection and Bandit protocol errors. Ship both, always (matrix, 05-7, 05-26, 05-35, 05-45).
2. One HTTP 500 is seen 3 to 4 times: Phoenix `router_dispatch` exc, `error_rendered`, Bandit exc, then the log, all in **one pid, telemetry first, logger last**. A pdict mark set by the telemetry handler is visible to the logger handler, so dedupe costs ~0.1 µs (05-5, 05-6, 05-59, 05-64).
3. Cowboy splits the same failure over the request pid and the connection pid, so the mark fails there. The exception and stacktrace are `==` across all sightings, so an ETS content key `phash2({mod, ex, st})` (1.9 µs) is the backstop (05-19, 05-22, 05-60, 05-61).
4. Normalization is not optional. Phoenix wraps controller errors in `Plug.Conn.WrapperError` (the inner conn is the one with the controller data), Cowboy nests `{{ex, st}, {plug, :call, _}}`, Oban turns `exit` into `CrashError` but a kill into raw `:killed` (05-3, 05-22, 05-51, 05-52: all red first runs).
5. Channel and LiveView crash reports carry `last_message` (topic, event, payload) and the whole `state` (socket, assigns), plus Phoenix's own `process_label`. That is free "what happened just before", and it holds secrets (05-26, 05-34, 05-36).
6. Logger metadata does not follow Tasks; `$callers` does, for requests, jobs and Tasks. Keep request/job context in ETS by pid and walk `callers` at crash time (05-10, 05-53, 05-62).
7. Ecto has no exception events. Handled errors (a `unique_violation` behind `unique_constraint`) look the same as real ones in query events, so query events are breadcrumbs only. Exception: pool exhaustion (`ConnectionError` after 225 ms) is logged nowhere and must become an issue (05-38, 05-42).
8. DBConnection failures come from connection pids: a dead DB logs `failed to connect` 10/s per connection (at 100 ms backoff), and an idle connection killed server-side is logged only when it is next used or pinged. Rate-limit by fingerprint, and never write events synchronously to the DB that is down (05-41, 05-44).
9. Hologram (source read): actions fail only in the browser, and commands raise in the request with no rescue, all grouped under the route `/hologram/command`, with module and name only in the serialized body. So 1charta needs a `set_context` call around commands and a small browser error endpoint. The lib must not know Hologram (section J).
10. Secrets are everywhere: raw params in every conn, `job.args`, channel payloads, LV assigns, query params. Copy a 184 B scrubbed request summary (not the 3.5 KB conn, `inspect` costs 120 µs), and scrub once, centrally (05-16, 05-64). 65 tests, 13 red on first run, 3 green full runs, no flakes.

## Experiments (appended one by one)

### Lab setup (verified)

`lab/05-frameworks/` is a `mix new` project on Elixir 1.20.4 / OTP 28, Apple M3 Pro. Locked
versions: phoenix 1.8.15, phoenix_live_view 1.2.12, bandit 1.12.5, thousand_island 1.5.0,
plug 1.20.3, plug_cowboy 2.9.0, cowboy 2.19.0, ecto 3.14.2, ecto_sql 3.14.0, postgrex 0.22.4,
db_connection 2.10.2, oban 2.24.1, req 0.7.4, finch 0.23.0, mint 1.10.1, telemetry 1.4.2.
Database `lab_0031_05`. Bandit endpoint on :4351, Cowboy endpoint on :4352, both started with
`start_supervised!` inside ExUnit.

`lib/lab05/capture.ex` installs (a) a `:logger` handler `:lab05_capture` at level `:all`
that sends `{:log, self(), event}` to the test pid, and (b) one `:telemetry.attach_many`
over 34 event names (every `:exception` event the stack documents, plus the `:stop`
events that carry errors in their result). Because the handler sends `self()`, every
sighting records **which process it ran in**; that is the basis for the dedupe claims.
The console handler is set to `:none` in `test_helper.exs`; the primary level is `:debug`
(printed by the helper).

Two lab bugs voided the first two runs and are not claims: the controller defined
`action/2` (which overrides `Phoenix.Controller.action/2`, so every route raised
FunctionClauseError), and `:inets` was missing from `extra_applications`.

### A. Phoenix 1.8 + Bandit: one controller raise, three sightings

File: `test/a_phoenix_bandit_test.exs`, 17 tests. First valid run: 15 green, 2 red (05-3, 05-8).

What one `raise "boom"` in a controller produces, in this order, **all in the same pid**
(the Bandit connection process that runs the plug; 05-5, 05-6, verified):

1. `[:phoenix, :router_dispatch, :exception]`: `kind: :error`, `reason`, `stacktrace`,
   `conn`, `route: "/raise"`, `plug: Lab05.Controller`, `plug_opts: :raise_`. **Red first
   run**: `reason` is not the RuntimeError but a `%Plug.Conn.WrapperError{kind, reason,
   stack, conn}`. `Phoenix.Controller.Pipeline.__catch__/5` wraps every `:error` raised in a
   controller (deps/phoenix/lib/phoenix/controller/pipeline.ex:155) and the router rescues
   the wrapper (router.ex:436). The `conn` in the metadata is the conn *before* the
   controller pipeline; the conn *inside* the wrapper carries `phoenix_action`, the
   controller's assigns and private data. A tracker must unwrap `WrapperError` and prefer
   the inner conn. `throw` and `exit` are not wrapped (`kind: :throw, reason: :oops`).
2. `[:phoenix, :error_rendered]`: `status: 500, kind, reason, stacktrace, log` (05-17).
3. `[:bandit, :request, :exception]`: metadata keys `[:stacktrace, :exception, :kind,
   :plug, :conn, :telemetry_span_context, :connection_telemetry_span_context]`, with the
   exception already unwrapped (05-4).
4. one `:logger` event at `:error`: `meta.crash_reason = {%RuntimeError{}, stacktrace}`
   and `meta.conn` = the `%Plug.Conn{}` (05-1, 05-2; Bandit puts the conn in the log
   metadata). `throw` logs `{{:nocatch, :oops}, st}`, `exit(:bye)` logs `{:bye, st}` (05-9).

So one failure is seen **three times** (router_dispatch, bandit, logger) plus once by
`error_rendered`. All three run synchronously in the request process, telemetry first,
logger last (05-6). That ordering is what makes cheap dedupe possible (see section G).

"Expected" errors (verified):

| case | status | `:error` log | router_dispatch exc | bandit exc | error_rendered |
|---|---|---|---|---|---|
| `raise` (RuntimeError) | 500 | yes | yes (WrapperError) | yes | 500 |
| exception with `plug_status: 404` (05-7) | 404 | **no** | yes | yes | 404 |
| unknown route, NoRouteError (05-8) | 404 | no | no | **no** (red first run) | 404 |
| `Phoenix.ActionClauseError` (05-11) | 400 | no | yes (not wrapped) | yes | 400 |
| malformed JSON, `Plug.Parsers.ParseError` (05-12) | 400 | no | no (raised in endpoint) | yes | 400 |
| `send_resp(conn, 500, ...)`, no raise (05-13) | 500 | no | no | no | no |
| `Repo.query!` Postgrex.Error (05-15) | 500 | yes | yes | yes | 500 |

05-8 red: Phoenix's `RenderErrors` renders a NoRouteError and does **not** reraise it
(deps/phoenix/lib/phoenix/endpoint/render_errors.ex:95 `maybe_raise(:error,
%NoRouteError{}, _)`), so Bandit never sees it; the only signal of a 404 is
`error_rendered` or the endpoint `:stop` with status 404. Bandit's logger stays silent for
any `plug_status` < 500 (its `log_exceptions_with_status_codes` default is 500..599), but
its telemetry exception fires for every status that escapes Phoenix.

A handled 500 (`send_resp(500)`, 05-13) is invisible to every hook except the `:stop`
events' `conn.status`. A tracker that wants "silent 500s" must watch
`[:phoenix, :endpoint, :stop]` (needs `Plug.Telemetry` in the endpoint, which every
generated Phoenix app has) or `[:bandit, :request, :stop]`.

`Logger.error` in a controller (05-14): metadata keys `[:line, :pid, :time, :file, :gl,
:domain, :application, :mfa, :user_id]`; no conn, no `request_id` (the lab endpoint has
no `Plug.RequestId`; with it, `request_id` would be in Logger metadata). The conn is only
reachable if the tracker stashed it in the process (see G).

`Task.start` crash from inside a request (05-10): a separate `:error` event from the task
pid, metadata `[:error_logger, :pid, :time, :gl, :domain, :report_cb, :callers,
:crash_reason]`; `callers` contains the request pid; no telemetry exception at all; the
request still returns 200. The request pid in `$callers` is the only link back to the
request.

Secrets (05-16): the conn in `router_dispatch` exception metadata holds raw params,
`"password" => "hunter2"`. Phoenix's `:filter_parameters` only applies to its own log
lines. The tracker must scrub.

### B. Plug.Cowboy for contrast: the same failure, but split across two processes

File: `test/b_phoenix_cowboy_test.exs`, 5 tests. First run: 4 green, 05-22 red.

Cowboy runs the plug in a **request process** spawned per stream by `cowboy_stream_h`;
the **connection process** owns the socket. Plug.Cowboy's handler catches the raise and
turns it into an `exit({{exception, stack}, {plug, :call, [conn, opts]}})`
(deps/plug_cowboy/lib/plug/cowboy/handler.ex:52-62). Then:

- `[:phoenix, :router_dispatch, :exception]` fires in the request process (as with Bandit).
- `[:cowboy, :request, :exception]` (from `cowboy_telemetry_h`) fires in the
  **connection** process: `meta.pid` is that connection pid (not the request pid; 05-22
  red first run), `meta.reason` is the whole nested exit reason
  `{{%RuntimeError{}, st}, {Lab05.CowboyEndpoint, :call, [conn, opts]}}`, and the request is
  a raw cowboy `req` map, not a `Plug.Conn` (keys `[:pid, :reason, :stacktrace, :kind,
  :ref, :req, :resp_status, :resp_headers, :streamid]`).
- The `:error` log comes from the **connection** process as well (05-19): Ranch/Cowboy's
  report, rewritten by `Plug.Cowboy.Translator` into `#PID<0.584.0> running
  Lab05.CowboyEndpoint (connection #PID<0.583.0>, stream id 1) terminated`, metadata
  `[:error_logger, :pid, :time, :gl, :domain, :report_cb, :conn, :crash_reason]`
  (05-18). The conn is in the metadata unless `:plug_cowboy, :conn_in_exception_metadata`
  is false (translator.ex:113).
- `plug_status` 404: no log (translator honours `:log_exceptions_with_status_code`,
  default `[500..599]`), cowboy telemetry still fires (05-20).
- `$callers` from a Task spawned in the request is the request pid (05-21), as with Bandit.

Consequence for dedupe: with Cowboy the logger event and the router_dispatch event are in
**different pids**, so "same pid, same exception" does not work. What does link them: the
exception struct itself (same term, `==`), and the conn in the log metadata is the same
`%Plug.Conn{}` owner-wise. Keying on `{exception module, message, top stack frame}` within
a short window works on both servers; keying on pid only works on Bandit.

Bandit logs (05-23): its raise log has `domain: [:elixir, :bandit]` (red first run: I
predicted `[:bandit]`; Elixir's Logger prefixes `:elixir`). A garbage request line
produces `:error` `** (Bandit.HTTPError) Request line HTTP error: "NOT HTTP AT ALL\r\n"`,
**no** exception telemetry (only `[:bandit, :request, :start|:stop]`, the stop carrying
`error:`) and no Phoenix event at all. Bandit's source: protocol errors (`Bandit.HTTPError`,
`TransportError`, HTTP/2 stream/connection errors) go to `stop_span` with `error:` and
`maybe_log_protocol_error`, never to `span_exception` (deps/bandit/lib/bandit/pipeline.ex:214-229).
A tracker should treat `domain: [:elixir, :bandit]` + `Bandit.HTTPError` as noise
(scanners, bad clients) by default, grouped but not alerted.

### C. Bare Plug (no Phoenix) on Bandit

File: `test/c_plug_test.exs`, 2 tests, both green first run.

- `Plug.Router` emits `[:plug, :router_dispatch, :exception]` with keys `[:reason,
  :stacktrace, :kind, :conn, :route, :router, :telemetry_span_context]`, `route:
  "/raise/:id"` (the pattern, good for grouping) (05-24).
- `Plug.ErrorHandler.handle_errors/2` runs in the request pid, sends its response, then
  the error is reraised and Bandit logs it once from the same pid (05-25). So an app's
  own ErrorHandler neither hides nor duplicates the error for a logger-based tracker.

### D. Phoenix channels over a real WebSocket

File: `test/d_channel_test.exs`, 7 tests over a real Bandit WebSocket (a 60-line raw
`:gen_tcp` client in `test/support/ws.ex`, V2 JSON frames, not `Phoenix.ChannelTest`, so
the transport process is the real one). First run: 6 green, 1 red (05-28, two sub-claims).
Stable across three random seeds.

- **handle_in raise** (05-26): exactly one `:error` event, from the channel pid, a
  `gen_server` crash report `{:report, %{label: {:gen_server, :terminate}, last_message,
  state, ...}}` with `domain: [:otp]` and `crash_reason: {%RuntimeError{}, st}`. The
  report carries **the last message** (`%Phoenix.Socket.Message{topic: "room:a", event:
  "boom", payload: %{"card" => 1}, ref: "2", join_ref: "1"}`) and **the state** (the
  `%Phoenix.Socket{}` with assigns). That is the "what happened just before" for free, but
  it also means the payload and assigns (tokens, user data) land in the event: scrub.
  **No telemetry exception event exists for channels**; `channel_handled_in` does not fire
  on a crash. The client gets `phx_error` `{"reason": "channel_crash"}`.
- The socket process survives a channel crash; other topics keep working (05-27).
- **join raise** (05-28, red): **two** `:error` events. The channel's gen_server crash
  report (channel pid, `process_label: {Phoenix.Channel, Lab05.Channel, "room:crash"}`) and
  a string `Logger.error` "an exception was raised: ..." from `Phoenix.Channel.Server.join/4`
  in the **transport** pid (deps/phoenix/lib/phoenix/channel/server.ex:50-56). The client
  gets `{"status": "error", "response": {"reason": "join crashed"}}`.
  `[:phoenix, :channel_joined]` does **not** fire (red): it is emitted after `join/3`
  returns (server.ex:318). Dedupe must fold the string log into the crash report (same
  exception text, within ms, transport pid = `state.transport_pid`).
- `{:reply, {:error, _}}` is silent: no log, `channel_handled_in` fires (05-29).
- **connect raise** (05-30): the upgrade is an ordinary HTTP request, so it looks like a
  controller raise without a router: HTTP 500, `error_rendered` + `[:bandit, :request,
  :exception]` + one `:error` log, no `router_dispatch`. `connect` returning `:error` is a
  silent 403 (05-31).
- **Linking a channel crash to its socket** (05-32): the crash report has no `callers`
  metadata (channels are started under a supervisor, not by the transport), but
  `state.transport_pid` equals the pid that emitted `[:phoenix, :socket_connected]`.
- Phoenix sets **process labels** itself via `Process.put(:"$process_label", ...)`:
  `{Phoenix.Channel, channel_module, topic}` for channels, `{Phoenix.Socket, handler, id}`
  for sockets (deps/phoenix/lib/phoenix/socket.ex:542, channel/server.ex:305). OTP 28 puts
  it in the crash report as `process_label`: free grouping context.

### E. LiveView 1.2 over a real WebSocket

File: `test/e_live_view_test.exs`, 4 tests, all green first run. Real protocol: dead
render over HTTP, scrape `data-phx-session`/`data-phx-static`, then `phx_join` on
`lv:<id>` over the WebSocket, then `event` frames (not `Phoenix.LiveViewTest`).

- **mount raise on the dead render** (05-33): HTTP 500; `[:phoenix, :live_view, :mount,
  :exception]` with keys `[:reason, :session, :socket, :stacktrace, :params, :uri, :kind]`,
  plus router_dispatch + bandit exception + one `:error` log, **all in the request pid**.
  Four sightings of one failure.
- **handle_event raise** (05-34): `[:phoenix, :live_view, :handle_event, :exception]` with
  `[:reason, :socket, :stacktrace, :params, :kind, :event]` and exactly one gen_server
  crash report, **both in the LV pid**. The report's `last_message` is the
  `%Phoenix.Socket.Message{event: "event", payload: %{"event" => "boom", "type" =>
  "click", "value" => ...}}`, and `process_label` is `{Phoenix.LiveView, Lab05.Live,
  "lv:phx-..."}`. The browser gets `phx_error` and (in real JS) remounts.
- **handle_info raise** (05-35): one crash report, **no** telemetry exception (LiveView has
  exception events only for mount, handle_params, handle_event, render and components'
  handle_event/update). Anything a LiveView does in `handle_info`/`handle_async` reaches a
  tracker only through the logger.
- The crash report's `state` contains every assign, here `secret: "hunter2"` (05-36).

For LiveView the telemetry event is strictly richer (event name, params, socket with
view/uri) but the logger sees every crash. Rule: logger is the net, telemetry enriches.

### F. Ecto, Postgrex, DBConnection

File: `test/f_ecto_test.exs`, 9 tests. First evaluations: 05-37..05-40 green; 05-41 red
twice, 05-42 red, 05-43 red, 05-41b and 05-44 green (05-44 needed a lab fix first). Final
suite stable across three random seeds.

Ecto has **no exception telemetry**. Its one event, `[app, :repo, :query]`, fires for
every statement including failed ones, with `result: {:error, e}` and metadata keys
`[:type, :options, :stacktrace, :result, :params, :source, :query, :repo, :cast_params]`
(05-37). `stacktrace` is there because Ecto 3.12+ captures the caller stack for query
events. Note `params` and `cast_params` are raw bind values (secrets, personal data).

| failure | caller sees | `[:repo, :query]` | `:error` log (from) |
|---|---|---|---|
| undefined table (05-37) | `{:error, %Postgrex.Error{code: :undefined_table}}` | `{:error, Postgrex.Error}` | none |
| unique violation **handled** by `unique_constraint` (05-38) | `{:error, changeset}` | `{:error, Postgrex.Error{code: :unique_violation}}` | none |
| same without the constraint | raises `Ecto.ConstraintError` | same | only if it escapes a process |
| `Repo.rollback(:why)` (05-39) | `{:error, :why}` | `begin`, `INSERT`, `rollback` all `{:ok, _}` | none |
| raise inside `transact` (05-40) | reraised, rolled back | `rollback` | none |
| idle conn killed server-side (05-41) | next user: `:ok` **or** `FATAL 57P01 admin_shutdown` | n/a | one "disconnected" (connection pid), **only when next used or pinged** |
| same, left idle (05-41b) | nobody | none | one "disconnected ... FATAL 57P01" within 2.5 s (idle ping, `idle_interval` 1000 ms) |
| pool exhausted (05-42) | `{:error, %DBConnection.ConnectionError{"...dropped from queue after 225ms..."}}` | `{:error, ConnectionError}` | **none** |
| client timeout (05-43) | `{:error, %Postgrex.Error{code: :query_canceled}}` | yes | one "disconnected: client #PID<...> ({label}) timed out ..." from the **connection** pid |
| DB unreachable (05-44) | (queries would fail) | none | 10 "failed to connect ... econnrefused" per second with backoff 100 ms |

What surprised (red first runs):

- 05-41: killing an idle connection logs **nothing** until the connection is used or
  pinged. The caller of the next checkout either got `FATAL 57P01` raised (run f1, a Task
  holder crashed with it; run f3) or was retried transparently after `tcp send: closed`
  (run f2). The tracker cannot expect a consistent signal; group all
  `Postgrex.Protocol ... disconnected` logs as one infrastructure issue.
- 05-42: `queue_target`/`queue_interval` are pool start options; passed per call they are
  silently ignored (the call waited 1349 ms and succeeded). With a 1-connection pool the
  drop comes after 225 ms, raises in the caller, is **not logged at all**, and is only
  visible in the query event. This is the classic "pool exhausted under load" failure:
  a logger-only tracker sees it only if the caller crashes.
- 05-43: a client timeout returns `query_canceled` to the caller, while the **connection**
  process logs the disconnect and names the client pid **with its process label** (here the
  ExUnit test name). This is a free cross-process link: parse `client #PID<...>` or,
  better, correlate by time with the caller's error.
- 05-44: a dead database floods the log at the backoff rate per pool connection (10/s
  here with pool_size 1 and backoff 100 ms; with defaults and pool_size 10 it is ~10
  connections × jittered 1-30 s). A tracker must rate-limit by fingerprint, and it must
  not store its own events in the same dead database synchronously (section G/D of the ADR).

Handled errors are the trap: 05-38 shows a perfectly normal "email already taken" form
error emitting `{:error, %Postgrex.Error{unique_violation}}` in the query event. A tracker
that turns every `{:error, _}` query result into an issue will be noise. Rule: query
events are breadcrumbs (what happened before), never issues on their own.

### G. Oban 2.24 with a real queue

File: `test/g_oban_test.exs`, 9 tests against a real `default` queue (Postgres notifier,
jobs inserted and executed, no `Oban.Testing`). First valid run: 7 green, 2 red (05-51,
05-52). Stable across three seeds.

**Oban never logs a failing job by default** (05-45, 05-51, 05-52: zero `:warning`+
events). Only `Oban.Telemetry.attach_default_logger/1` would, and it is opt-in. A
logger-only tracker misses every Oban failure. The one source is telemetry.

`[:oban, :job, :exception]` metadata keys (05-45): `[:args, :attempt, :conf, :error, :id,
:job, :kind, :max_attempts, :prefix, :queue, :reason, :result, :stacktrace, :state,
:tags, :worker]`. `job.args` holds whatever the app enqueued (here `"secret" =>
"hunter2"`): scrub.

| job does | event | kind / reason | state |
|---|---|---|---|
| raises, attempts left (05-45) | exception | `:error`, `%RuntimeError{}` | `:failure` |
| raises on last attempt (05-46) | exception | same | `:discard` |
| returns `{:error, "nope"}` (05-47) | exception | `:error`, `%Oban.PerformError{}` | `:failure` |
| `{:cancel, _}` (05-48) | **stop** | none | `:cancelled` |
| `{:snooze, 60}` (05-49) | stop | none | `:snoozed` |
| exceeds `timeout/1` (05-50) | exception | `%Oban.TimeoutError{}` | `:failure` |
| `Process.exit(self(), :kill)` (05-51, red) | exception | `:exit`, `:killed` (raw) | `:failure` |
| `exit(:bye)` (05-52, red) | exception | `:error`, `%Oban.CrashError{reason: :bye}` | `:failure` |

I predicted the opposite for 05-51/52 (kill wrapped in `CrashError`, `exit` raw). The
tracker must normalize: the `:error` key holds an exception struct when Oban had one.

`state` is the grouping hint the UI needs: `:failure` = will retry (show as "retrying,
attempt 1/3"), `:discard` = final failure (alert). A tracker should raise an issue on
`:discard` and count `:failure` as occurrences, or users get one alert per retry.

The exception event runs in the job's own process (same pid as `[:oban, :job, :start]`,
05-53), so per-process breadcrumbs collected during the job are reachable from the
handler. A Task spawned by a job crashes with `$callers = [job pid]` (05-53).

### H. Req and Finch

File: `test/h_req_test.exs`, 5 tests against a Bandit upstream on :4354. First run: 3
green, 2 red (both about the Finch telemetry result shape). Stable across three seeds.

- Req has **no telemetry of its own** (grep of deps/req/lib: only doc mentions of
  `Finch.Telemetry`). HTTP failures are values, not exceptions: a 500 is `{:ok,
  %Req.Response{status: 500}}`, a refused connection `{:error, %Req.TransportError{reason:
  :econnrefused}}`, a receive timeout `{:error, %Req.TransportError{reason: :timeout}}`
  (05-54, 05-56, 05-57). Only `Req.get!` raises (05-58), and then it is an ordinary
  exception in the caller.
- **Req's default retry logs** (05-55): a GET that gets 500 is retried three times with
  `:warning` logs "retry: got response with status 500, will retry in 10ms, 3 attempts
  left" from the **caller's** pid; four `[:finch, :request, :stop]` events. These warnings
  are the only logger trace of a failing upstream, and they land in the request process:
  perfect breadcrumbs, and a tracker at `:warning` would see them as noise if it made issues
  of them.
- `[:finch, :request, :stop]` has keys `[:name, :request, :result, :telemetry_span_context]`.
  Red first run twice: because Req drives `Finch.stream/5`, `result` is **the stream
  accumulator**, `{:ok, {%Req.Request{}, {500, headers, body, trailers}}}`, and on error a
  **3-tuple** `{:error, %Finch.TransportError{reason: :econnrefused, source:
  %Mint.TransportError{}}, acc}` (05-54, 05-56). A breadcrumb extractor must pattern-match
  `{:error, e, _}` as well as `{:error, e}`, and must not assume a `%Finch.Response{}`.
  `[:finch, :request, :exception]` fires only if the stream fun itself raises.
- For "what happened before", an outbound HTTP breadcrumb = `request.method`, `host`,
  `path` (not query, not headers), status or error reason, duration from the measurement.

### I. Dedupe: one failure, many sightings

File: `test/i_dedupe_test.exs` + `lib/lab05/dedupe.ex` (30 lines), 5 tests, all green
first run, stable across three seeds.

The spike: the telemetry handler unwraps the exception and pushes it onto a list in the
process dictionary (`Process.put(:lab05_seen, ...)`); the `:logger` handler, which runs in
the process that logged, checks `exception in Process.get(:lab05_seen)`.

- **Bandit** (05-59): the logger handler **sees the mark**. Telemetry runs first in the
  same process, the log comes last (05-6). Dedupe costs one `Process.put` and one list
  membership check, no shared state, no time window.
- **Cowboy** (05-60): the mark is **not** visible (log in the connection pid, router in
  the request pid). Needs a content key.
- **LiveView handle_event** (05-63): the crash report is emitted by `gen_server` in the
  dying LV process after the telemetry exception, so the mark is visible there too.
- **Content key** (05-61): the exception term is `==` across the unwrapped router_dispatch
  reason, the bandit exception and the log's `crash_reason`, and so is the stacktrace
  (router_dispatch's own `stacktrace` equals `WrapperError.stack` equals the log's). So a
  key of `{kind, exception module, :erlang.phash2(exception), phash2(stacktrace)}` in a
  small ETS table with a 5 s TTL dedupes Cowboy and anything else across processes.
- **Logger metadata does not follow Tasks** (05-62): `Logger.metadata(request_id: ...)`
  in the request is absent from a Task's crash log; only `callers` links it. The tracker
  should keep its per-request context keyed by pid (ETS) so a crash in a child can look up
  its `callers` chain.

Recommended order inside the lib: the pdict mark as the fast path (Bandit, LiveView,
channels' join string log is a separate pid), and the content key as the backstop.

### J. Hologram 0.11.1 (source read only, not run)

Read from `/Users/lennartbuttner/Projects/1charta/deps/hologram` (0.11.1, mix.lock) and
1charta's `lib/charta_web/endpoint.ex`. Nothing here was executed; all **read**.

- **Mounting.** 1charta's endpoint runs `plug Hologram.Router` (endpoint.ex:63) before
  `ChartaWeb.Router`, after `Plug.RequestId` and `Plug.Telemetry`. `Hologram.Router` is a
  `Plug.Router` (deps/hologram/lib/hologram/router.ex:4), so it emits the **Plug**
  `[:plug, :router_dispatch, :start|:stop|:exception]` events (05-24 shape), never
  Phoenix's `router_dispatch`.
- **Actions run in the browser.** A Hologram action is Elixir compiled to JS; a failure
  throws in the page. The server never hears of it. The client funnels uncaught errors
  through `window.addEventListener("error")` and `"unhandledrejection"` into
  `Hologram.handleUncaughtError` (assets/js/hologram.mjs:1112-1120), which records
  `lastBoxedError = {module: error.type, message: error.text}` and shows an overlay when
  `config.errorOverlay` is set (hologram.mjs:415-425). The client "Logger" only appends to
  `sessionStorage` (assets/js/logger.mjs). So a tracker needs its **own browser endpoint**
  (POST, rate-limited) and a tiny script that listens to the same two window events; it
  must not depend on Hologram, but 1charta can wire it next to Hologram's listener.
- **Commands run on the server, in the request process, with no rescue.**
  `POST /hologram/command` (router.ex:26) calls `Controller.handle_command_request/1`,
  which deserializes the payload and calls `module.command(name, params, server)`
  directly (controller.ex:242-405). A raise propagates to the endpoint: Plug
  router_dispatch exception with **`route: "/hologram/command"` for every command**,
  Phoenix `error_rendered` 500, Bandit exception, one `:error` log (the Bandit shape from
  section A). The **command module and name are not in any metadata**; they are only in
  `conn.body_params["_json"]` in Hologram's serialized form. The client turns the non-2xx
  into `HologramRuntimeError("command failed: 500")` (assets/js/client.mjs:181, 228).
  Without help a tracker groups every failing command under one route. Fix in 1charta, not
  in the lib: a tiny wrapper that sets `Logger.metadata(hologram_command: {module, name})`
  (or the lib's `Blackbox.context/1`) before dispatch, or the lib offers a documented
  "route namer" callback.
- **Silent command failure.** If the command's next action cannot be encoded,
  `command_status` is 0 (controller.ex:380-381), the HTTP response is 200 JSON, nothing
  is logged, and the client throws `command failed: <action>`. Only a browser reporter
  sees it.
- **Pages.** The catch-all `match _` (router.ex:69-75) renders pages via
  `handle_initial_page_request/2`; a raise in `init/3` or a template behaves like a command
  raise (500 through Bandit) with the catch-all route.
- **Realtime.** `GET /hologram/sse` holds a long-lived request process in a `receive`
  loop (lib/hologram/realtime/sse.ex:89-120). A crash there is a Bandit request crash
  (logged, 500 is moot since chunks were sent). `/hologram/websocket` is a `WebSock`
  (lib/hologram/runtime/connection.ex) used for pings and dev reload; its `handle_in`
  has no rescue, so a crash would be a Bandit WebSocket crash.
- **Warnings Hologram logs itself:** 3 `Logger.error|warning` call sites in lib: CSRF
  token validation failed (403), instance_id cross-check failed (403)
  (controller.ex:274, 282), and "No connection attached for instance ... subscription
  deltas were not applied" (subscription_registry.ex:659-668). Useful breadcrumbs; the
  first two are security signals worth counting.
- Hologram emits **no runtime telemetry** (only `[:hologram, :compiler, :start|:stop]`
  in the mix compiler task) and sets no process labels or Logger metadata.

### K. Costs (verified, Apple M3 Pro, OTP 28)

File: `test/k_cost_test.exs`, 1 test, 3 runs + 1. Using the real conn, exception and
stacktrace from a `POST /secret` controller raise (14 frames):

| operation | per op |
|---|---|
| pdict mark + membership check (dedupe fast path) | 0.095 to 0.119 µs |
| `:erlang.phash2({module, exception, stacktrace})` (content key) | 1.85 to 1.92 µs |
| `inspect(conn, limit: :infinity)` | 113 to 128 µs |
| `:erlang.external_size(conn)` | 3533 B |
| a picked, scrubbed summary (method, path, route, status, filtered params, ip) | 184 B |

Red first run: I predicted the conn over 5 KB; it is 3.5 KB for a small JSON request
(bigger with cookies, sessions, assigns). Rule: never keep or `inspect` the conn in the
hot path; copy ~10 fields (~0.2 KB), scrub params there, and do any formatting in the
writer process.

### Whole suite

65 tests in 10 files, `mix test` three times with random seeds 687900, 573321, 903000:
`Result: 65 passed` each (about 28 s, all sync). No flaky test observed. Per file, the
first-run outcome of each claim is in the table below.

## Claims table

First run = the first run in which the claim was actually evaluated (runs voided by lab
bugs are listed in the log and not counted). Test names are `"05-k: ..."` in
`lab/05-frameworks/test/`.

| id | claim (final truth) | first run | file |
|---|---|---|---|
| 05-1 | Bandit+Phoenix controller raise: exactly one `:error` log, `crash_reason = {exception, st}` | green | a |
| 05-2 | Bandit puts `conn` in the log metadata | green | a |
| 05-3 | router_dispatch `:exception` fires once; for a controller `:error` its reason is `%Plug.Conn.WrapperError{}`, inner conn carries the controller data, outer conn does not | **red** (predicted the bare RuntimeError) | a |
| 05-4 | `[:bandit, :request, :exception]` fires once, keys `stacktrace, exception, kind, plug, conn, ...`, exception unwrapped | green | a |
| 05-5 | log, router_dispatch and bandit sightings all run in one pid | green | a |
| 05-6 | order: router_dispatch exc, error_rendered, bandit exc, log | green | a |
| 05-7 | `plug_status: 404` exception: no log, router_dispatch + bandit exc fire | green | a |
| 05-8 | NoRouteError: no log, no router_dispatch, **no bandit exc**, only error_rendered 404 | **red** (predicted bandit exc) | a |
| 05-9 | throw/exit logged with `{{:nocatch, v}, st}` / `{reason, st}`; router_dispatch kind :throw unwrapped | green | a |
| 05-10 | `Task.start` crash in a request: log from the task pid, `callers` has the request pid, no telemetry | green | a |
| 05-11 | ActionClauseError: 400, no log, router_dispatch exc (unwrapped), error_rendered 400 | green | a |
| 05-12 | malformed JSON: 400, no log, no router_dispatch, bandit exc, error_rendered 400 | green | a |
| 05-13 | `send_resp(500)` without raise: invisible except `:stop` status | green | a |
| 05-14 | `Logger.error` in a controller: `mfa`, `user_id`, no conn, no request_id (no RequestId plug) | green | a |
| 05-15 | `Repo.query!` error in a controller: logged, query event has `{:error, Postgrex.Error}` | green | a |
| 05-16 | router_dispatch conn holds raw params (password unfiltered) | green | a |
| 05-17 | `error_rendered` has status 500, kind, reason, stacktrace | green | a |
| 05-18 | Cowboy: one log with `crash_reason` and `conn`, text "... running Endpoint (connection ...) terminated" | green | b |
| 05-19 | Cowboy: cowboy exc fires once; log and cowboy exc share the connection pid, router_dispatch is another pid | green | b |
| 05-20 | Cowboy: `plug_status` 404 not logged, cowboy exc fires | green | b |
| 05-21 | Cowboy: Task crash `callers` = request pid | green | b |
| 05-22 | Cowboy exc `meta.pid` is the connection pid; `reason` is the nested exit `{{ex, st}, {plug, :call, [conn, opts]}}` | **red** (predicted request pid) | b |
| 05-23 | Bandit log domain is `[:elixir, :bandit]`; a garbage request line: one `:error` log, no exception telemetry, no Phoenix event | **red** (predicted `[:bandit]`) | a |
| 05-24 | bare Plug.Router emits `[:plug, :router_dispatch, :exception]` with the route pattern | green | c |
| 05-25 | Plug.ErrorHandler runs in the request pid, then Bandit logs once | green | c |
| 05-26 | channel handle_in raise: one gen_server crash report with `last_message` (the Message, payload) and `state` (the socket); no telemetry; `phx_error` to client | green | d |
| 05-27 | socket survives a channel crash | green | d |
| 05-28 | join raise: **two** `:error` logs (crash report in channel pid + string log in transport pid), **no** `channel_joined` | **red** (predicted one log and channel_joined :error) | d |
| 05-29 | `{:reply, {:error, _}}`: silent, channel_handled_in fires | green | d |
| 05-30 | raise in `UserSocket.connect`: HTTP 500 on upgrade, bandit exc + log, no router_dispatch | green | d |
| 05-31 | connect `:error`: 403, nothing logged | green | d |
| 05-32 | channel crash log has no `callers`; `state.transport_pid` = socket_connected pid | green | d |
| 05-33 | LV mount raise on dead render: mount exc + router_dispatch + bandit + one log, one pid | green | e |
| 05-34 | LV handle_event raise: handle_event exc + one crash report, same pid; `process_label` `{Phoenix.LiveView, view, topic}` | green | e |
| 05-35 | LV handle_info raise: crash report only, no telemetry | green | e |
| 05-36 | LV crash report state holds all assigns incl. a secret | green | e |
| 05-37 | query error: `{:error, Postgrex.Error}`, query event carries it, nothing logged | green | f |
| 05-38 | handled unique violation: `{:error, changeset}` but the query event carries `Postgrex.Error{unique_violation}` | green | f |
| 05-39 | `Repo.rollback`: begin/insert/rollback query events, nothing logged | green | f |
| 05-40 | raise in `transact`: rolled back, reraised, no log | green | f |
| 05-41 | idle conn killed server-side: nothing logged at once; next checkout logs "disconnected"; caller gets `:ok` or FATAL 57P01 | **red** twice (predicted an immediate log; then predicted FATAL always) | f |
| 05-41b | idle killed conn found by the idle ping within 2.5 s, one log | green | f |
| 05-42 | pool exhausted (pool start options): `ConnectionError` after 225 ms to the caller, query event carries it, nothing logged | **red** (per-call `queue_target` is ignored) | f |
| 05-43 | client timeout: caller gets `Postgrex.Error{query_canceled}`; connection pid logs "disconnected: client #PID<...> (label) timed out" | **red** (predicted ConnectionError to caller) | f |
| 05-44 | DB unreachable: "failed to connect" `:error` every backoff (10/s at 100 ms), no telemetry | green | f |
| 05-45 | Oban raise: `[:oban, :job, :exception]`, state `:failure`, `job.args` raw; **no log** | green | g |
| 05-46 | last attempt: state `:discard` | green | g |
| 05-47 | `{:error, _}`: exception with `%Oban.PerformError{}` | green | g |
| 05-48 | `{:cancel, _}`: `:stop` with state `:cancelled`, no exception | green | g |
| 05-49 | `{:snooze, 60}`: `:stop` with state `:snoozed` | green | g |
| 05-50 | timeout: `%Oban.TimeoutError{}` | green | g |
| 05-51 | killed job: kind `:exit`, reason `:killed`; no log | **red** (predicted CrashError) | g |
| 05-52 | `exit(:bye)` in a job: kind `:error`, `%Oban.CrashError{reason: :bye}`; no log | **red** (predicted kind :exit raw) | g |
| 05-53 | Oban exception runs in the job pid; a Task from a job has `callers` = job pid | green | g |
| 05-54 | Req 500 with `retry: false` is `{:ok, 500}`; finch `:stop` result is Req's stream accumulator `{:ok, {req, {500, h, b, t}}}` | **red** twice (predicted `%Finch.Response{}`, then `%Req.Response{}`) | h |
| 05-55 | Req default retry: 3 `:warning` logs in the caller pid, 4 finch requests | green | h |
| 05-56 | refused: `Req.TransportError{:econnrefused}`; finch stop result `{:error, %Finch.TransportError{}, acc}`; no exc, no log | **red** (predicted a 2-tuple) | h |
| 05-57 | receive timeout: `Req.TransportError{:timeout}` | green | h |
| 05-58 | `Req.get!` raises `Req.TransportError` | green | h |
| 05-59 | Bandit: logger handler sees the pdict mark set by the telemetry handler | green | i |
| 05-60 | Cowboy: it does not | green | i |
| 05-61 | exception and stacktrace are `==` across router_dispatch (unwrapped), bandit exc and log | green | i |
| 05-62 | Logger metadata (request_id) is not inherited by a Task's crash log; only `callers` | green | i |
| 05-63 | LiveView handle_event: the mark is visible to the crash report | green | i |
| 05-64 | pdict mark ~0.1 µs, phash2 key ~1.9 µs, conn 3.5 KB vs 184 B summary, `inspect(conn)` ~120 µs | **red** (predicted conn > 5 KB) | k |

65 tests; 13 claims red on first evaluation, all now asserting the observed behaviour.

## Capture matrix: which hook sees what (verified unless marked)

| failure | `:logger` handler | telemetry exception | only other signal |
|---|---|---|---|
| controller raise, 5xx (Bandit / Cowboy) | yes (conn in meta) | Phoenix router_dispatch + bandit / cowboy | |
| controller raise with `plug_status` < 500 | **no** | router_dispatch + server | error_rendered |
| NoRouteError | no | **no** | error_rendered, endpoint stop 404 |
| handled 500 (`send_resp`) | no | no | endpoint / bandit stop status |
| Bandit protocol error (bad request line) | yes | no | bandit stop `error:` |
| Task/spawn crash inside a request or job | yes (`callers`) | no | |
| channel handle_in / join raise | yes (crash report; join: +string log) | **none exist** | |
| socket connect raise | yes | bandit | |
| LiveView mount/handle_event/handle_params/render raise | yes (crash report) | LV `:exception` | |
| LiveView handle_info / handle_async raise | yes | **no** | |
| Ecto query error in a process that survives | no | no (not an exception event) | query event `{:error, _}` |
| pool exhausted, caller handles it | no | no | query event `{:error, ConnectionError}` |
| DB connection dies / DB down | yes (DBConnection, conn pid) | no | |
| Oban job raises / errors / times out / is killed | **no** (by default) | `[:oban, :job, :exception]` | |
| Oban cancel / snooze | no | no | `[:oban, :job, :stop]` state |
| Req upstream 500 / refused / timeout, handled | only Req's retry `:warning` | no | finch stop result |
| Hologram command raise (read) | yes (Bandit) | Plug router_dispatch `/hologram/command` + bandit | |
| Hologram command whose result cannot be encoded (read) | no | no | none server-side (client throws) |
| Hologram action (client) failure (read) | no | no | browser only (window error events) |

Neither hook alone is enough: the logger misses every Oban failure and every expected
(4xx) exception; telemetry misses channels, `handle_info`, Tasks, DBConnection and
Bandit protocol errors.

## Findings

| id | what | evidence | priority | proposal (one line) | size |
|---|---|---|---|---|---|
| F1 | Oban failures never reach the logger by default | 05-45, 05-51, 05-52 | high | attach `[:oban, :job, :exception]`; open an issue on `:discard`, count `:failure` as occurrences | S |
| F2 | One HTTP failure is seen 3-4 times (router_dispatch, error_rendered, server exc, log; LV adds a fourth) | 05-5, 05-6, 05-33 | high | pdict mark from telemetry, checked by the logger handler; ETS content key as backstop | S |
| F3 | Cowboy splits the sightings over two pids; the pdict mark fails there | 05-19, 05-22, 05-60 | medium | content key `phash2({mod, ex, st})` with a 5 s TTL, ~1.9 µs | S |
| F4 | Phoenix wraps controller errors in `Plug.Conn.WrapperError`; the metadata conn is the pre-controller conn | 05-3 | high | unwrap everywhere; prefer `wrapper.conn` for the request snapshot | S |
| F5 | Channels have no exception telemetry; crash reports carry `last_message` and `state` | 05-26, 05-28, 05-32 | high | parse gen_server crash reports: Message topic/event/payload become the event's "last message", scrubbed | M |
| F6 | Join crash logs twice from two pids | 05-28 | low | fold a `Phoenix.Channel.Server.join/4` string log into the crash report within 1 s | S |
| F7 | 4xx exceptions and NoRouteError are invisible to the logger; NoRouteError is invisible to server telemetry too | 05-7, 05-8, 05-11, 05-12 | medium | record 4xx from `error_rendered` as low-severity counters, not issues (configurable) | S |
| F8 | Handled 500s are invisible except in `:stop` events | 05-13 | medium | optional "silent 5xx" watcher on `[:phoenix, :endpoint, :stop]` | S |
| F9 | DB pool exhaustion is not logged; only the query event shows it | 05-42 | high | treat `DBConnection.ConnectionError` in query events as an issue even if handled | S |
| F10 | Handled DB errors (unique_violation) appear in query events | 05-38 | high | query events are breadcrumbs only, never issues (except F9) | S |
| F11 | DB down floods `failed to connect` at backoff rate per connection | 05-44 | high | fingerprint rate limit; never write events synchronously to the app DB | M |
| F12 | Client timeout logs name the client pid and its process label | 05-43 | low | parse `client #PID<..>` to link the connection log to the caller's issue | S |
| F13 | Logger metadata does not follow Tasks; `$callers` does | 05-10, 05-21, 05-53, 05-62 | high | keep request/job context in ETS keyed by pid; resolve through `callers` at crash time | M |
| F14 | Secrets in params, `job.args`, LV assigns, channel payloads, query params | 05-16, 05-36, 05-45, 05-26 | high | one scrubber over every captured map (key names + Phoenix `:filter_parameters`) | M |
| F15 | Keeping the conn is 3.5 KB, `inspect` ~120 µs | 05-64 | medium | copy ~10 fields (184 B) in the handler; format in the writer | S |
| F16 | Hologram commands all group under route `/hologram/command`; module/name only in the body | read, controller.ex:242-405 | high (for 1charta) | a public `Blackbox.set_context/1` that 1charta calls around `module.command/3` | S |
| F17 | Hologram action errors and undecodable command results exist only in the browser | read, hologram.mjs:1112, controller.ex:380 | high (for 1charta) | a small browser endpoint + script; 1charta adds it next to Hologram's listener | M |
| F18 | Req/Finch result shapes vary (stream acc, 3-tuple errors) | 05-54, 05-56 | low | breadcrumb extractor matches `{:ok, _}`, `{:error, e}`, `{:error, e, _}` | S |
| F19 | Phoenix and LiveView set process labels; OTP 28 puts them in crash reports | 05-28, 05-34 | medium | store `process_label` on every event and use it in grouping/UI | S |
| F20 | Bandit protocol errors (`Bandit.HTTPError`) are logged at `:error` with domain `[:elixir, :bandit]` | 05-23 | low | classify as noise by default (counted, not alerted) | S |

## Recommendations for the lib

1. **Two hooks, always together.** One `:logger` handler (the net: crash reports,
   Bandit/Cowboy/DBConnection logs, Tasks, channels, `handle_info`) and one telemetry
   attach list (the enrichment and the only source for Oban and 4xx). Default list:
   `[:phoenix, :router_dispatch, :exception]`, `[:phoenix, :error_rendered]`,
   `[:plug, :router_dispatch, :exception]`, `[:bandit, :request, :exception]`,
   `[:cowboy, :request, :exception]`, `[:phoenix, :live_view, :mount|:handle_params|:handle_event|:render, :exception]`,
   `[:phoenix, :live_component, :handle_event|:update, :exception]`,
   `[:oban, :job, :exception]`. Attach only to events whose app is loaded.
2. **Dedupe in two steps.** Telemetry handler: normalize (unwrap `WrapperError`,
   Cowboy's nested exit, Oban's `:error` key), build the event, put
   `{phash2 key}` into the process dictionary. Logger handler: if the key is in the
   pdict, attach the log's extra fields (e.g. Bandit's conn) to the same event and stop.
   Otherwise check a TTL'd ETS set of recent keys (Cowboy, cross-process), else it is a new
   event. Cost measured: 0.1 µs and 1.9 µs.
3. **Normalizer table per source**, tested with these 65 cases as fixtures: `crash_reason`
   `{ex, st}` / `{{:nocatch, v}, st}` / `{reason, st}`; `WrapperError`; Cowboy
   `{{ex, st}, {plug, :call, [conn, opts]}}`; Oban `PerformError` / `CrashError` /
   `TimeoutError` / raw `:killed`; gen_server crash reports (label, last_message, state,
   process_label).
4. **Request snapshot, not the conn.** Copy `method, request_path, route (pattern), status,
   params (scrubbed), request_id, remote_ip, user_agent, phoenix_controller/action or
   plug` from the innermost conn (`WrapperError.conn` if present). About 0.2 KB.
5. **Context through `$callers`.** On `[:phoenix, :endpoint, :start]`, `[:oban, :job,
   :start]`, LV mount, channel join: record `{pid => context}` in ETS (and delete on
   `:stop`). A crash in any pid walks `callers` (then `ancestors`) to find the request or
   job it belongs to. Logger metadata is not enough (05-62).
6. **Crash reports are the channel/LiveView "before".** Extract `last_message` (for
   Phoenix: topic, event, scrubbed payload) and a scrubbed, size-capped `state` summary;
   keep `process_label`.
7. **Severity classes.** Issue: 5xx exceptions, crashes, Oban `:discard`, pool
   exhaustion, DB disconnect storms. Occurrence without alert: Oban `:failure` retries.
   Counter only (configurable): 4xx exceptions, NoRouteError, Bandit protocol errors,
   Req retry warnings. Breadcrumb only: query events, finch stops, `:warning` logs.
8. **Rate-limit by fingerprint in the handler** (DB down = 10 logs/s per connection, 05-44)
   and never write to the app's Repo from the handler; the writer must tolerate the DB
   being the thing that is down.
9. **Scrub once, centrally**, with Phoenix's `:filter_parameters` plus a default list
   (`password, token, secret, authorization, cookie, api_key`), applied to params,
   `job.args`, channel payloads, LV assigns, query params.
10. **Hologram adapter lives in 1charta, not the lib.** The lib offers
    `Blackbox.set_context(map)` (pdict) and a browser error endpoint + 1 KB script; 1charta
    wraps `module.command/3` to set `%{hologram: {module, name}}` and loads the script
    next to Hologram's `handleUncaughtError`.
11. **Optional watchers**, off by default: silent 5xx from `:stop` events; LiveView
    `handle_info` has no telemetry, so it depends on the logger only (already covered).

## Sources

All versions from `lab/05-frameworks/mix.lock`; paths relative to `lab/05-frameworks/`.

- Lab: `docs/research/0031-errors/lab/05-frameworks/` (tests in `test/a_*.exs` to
  `test/k_*.exs`, capture in `lib/lab05/capture.ex`, dedupe spike in
  `lib/lab05/dedupe.ex`, WebSocket client `test/support/ws.ex`). Logs:
  `docs/research/0031-errors/logs/05-frameworks.log`, `logs/05-run-*.log`. **verified**
- Phoenix 1.8.15: `deps/phoenix/lib/phoenix/router.ex:425-450` (router_dispatch
  exception, WrapperError); `lib/phoenix/controller/pipeline.ex:144-156` (wrapping);
  `lib/phoenix/endpoint/render_errors.ex:6,95-96` (NoRouteError not reraised);
  `lib/phoenix/channel/server.ex:50-56,305-318` (join logs, label, channel_joined);
  `lib/phoenix/socket.ex:542-548` (socket label). **read**
- Bandit 1.12.5: `deps/bandit/lib/bandit/pipeline.ex:200-245` (handle_error, protocol
  errors, `log_exceptions_with_status_codes`); `lib/bandit/logger.ex:48-63` (metadata,
  domain, crash_reason). **read**
- Plug.Cowboy 2.9.0: `deps/plug_cowboy/lib/plug/cowboy/handler.ex:21-62` (exit shape);
  `lib/plug/cowboy/translator.ex:8-120` (translation, status filter, conn metadata). **read**
- Req 0.7.4: `deps/req/lib/req/steps.ex` (retry and redirect log levels); no telemetry. **read**
- Hologram 0.11.1 (1charta `deps/hologram`): `lib/hologram/router.ex`,
  `lib/hologram/controller.ex:242-405`, `lib/hologram/runtime/connection.ex`,
  `lib/hologram/realtime/sse.ex`, `lib/hologram/realtime/subscription_registry.ex:659-668`,
  `assets/js/client.mjs:170-233`, `assets/js/hologram.mjs:415-425,1112-1120`,
  `assets/js/logger.mjs`; 1charta `lib/charta_web/endpoint.ex:50-64`. **read**
- Oban 2.24.1, Ecto 3.14.2, ecto_sql 3.14.0, Postgrex 0.22.4, DBConnection 2.10.2,
  Finch 0.23.0, LiveView 1.2.12, Plug 1.20.3: behaviour **verified** by the tests above.
