# 07 1charta source and packaging

## Summary for the lead

1. **Prod keeps no error history.** Only stdout, the container is recreated on every deploy (today 07:37 UTC), logs capped at 50 MB: the 168 h query returned 3,683 lines, all `[info]`, 0 errors. Store events in 1charta's own Postgres.
2. **Privacy is the hard constraint.** Board secrets are in request paths (`/b/<id>`, `?key=ck_`), and a `Charta.Board.Server` crash report would carry the whole board as GenServer state (no `format_status/1`). Scrub paths, truncate and redact state by default; add `format_status/1` in 1charta.
3. **A browser error tracker already exists, write-only:** `board.js` -> `POST /tab/error` -> `tab_error` rows (60/min/board, 30-day prune, sealed boards send only same-origin frames). Nobody reads them but SQL. Make it the lib's `:browser` source.
4. **No quotable error id:** ErrorHTML ("1charta had trouble") and ErrorJSON carry no ref. Add the event id to both; it is what a person or agent pastes.
5. **Hologram needs no special hook:** commands run inside `ChartaWeb.Endpoint` with no rescue (`controller.ex:355`), so Plug/Bandit/logger see them; actions run in the browser. Two gaps: encode failure = 200 + `status: 0` with no server log; SSE `max_heap_size` kills are VM reports with no exception.
6. **erl_crash.dump (2026-09-20 15:49)** is a `mix test test/charta/members_test.exs` in the repo root whose IO server (`user`, `standard_error`) was already gone: `:terminated` in a GenServer.stop, then `badarg` printing it, "Runtime terminating during boot". Not a 1charta bug; the slogan is truncated at 1032 chars and binaries are byte lists.
7. **Release:** OTP 28.5.0.6 / Elixir 1.20.4, no sources in the image, `BUILD_SHA` -> `Charta.build/0`, no `ERL_CRASH_DUMP`. Carry `(sha, file, line)`; agents resolve source from the repo at that sha.
8. **Path dep `packages/blackbox`** works with `mix release`, but the Dockerfile must `COPY packages` before `deps.get`, the dev reloader needs `reloadable_apps: [:charta, :blackbox]`, and Hologram pulls every loaded app's modules into its call graph, so never call the lib from actions. The package's own `mix test` (own `_build`) is safe beside the dev server.
9. **Name: `blackbox` is free on hex** (2026-09-27); `black_box` is a dead 2018 package; `flight_recorder`, `postmortem`, `tombstone` also free. Hard dep only `:telemetry`.
10. **Agents:** follow ADR 0012 (files over MCP): a JSON+Markdown API (list, show, `.md`, resolve-in-build, ignore) behind its own env token, dev-only Markdown files under `tmp/blackbox/`, MCP last. Prod DB reads by Claude were refused by the classifier, so the user decides access.

## 1. Source map: how 1charta logs and fails today

All paths at HEAD b4d1c71 plus the working tree of 2026-09-27 (branch `sidecar`). **read** unless marked.

### 1.1 Logger config (read)

| where | what |
|---|---|
| `config/config.exs:35-37` | `:default_formatter` `"$time $metadata[$level] $message\n"`, metadata `[:request_id]` only |
| `config/dev.exs:58` | dev formatter `"[$level] $message\n"` (no metadata, no time) |
| `config/prod.exs:18` | `config :logger, level: :info` (primary level :info in prod: `Logger.debug` breadcrumbs are dropped before any handler, unless the lib lowers the primary level) |
| `config/test.exs:28` | `level: :warning` |
| `config/config.exs:43` | `filter_parameters: ["password", "key"]` (agent keys `?key=ck_...` stay out of Phoenix's log; the lib's scrubber must honour this same list) |
| `config/runtime.exs:31` | `render_errors: [html: ChartaWeb.ErrorHTML, json: ChartaWeb.ErrorJSON]` |
| `config/dev.exs:27` | `debug_errors: true` (Phoenix debug page in dev) |

No custom `:logger` handler, no `Logger` backend, no filter, no JSON formatter: the only handler is OTP's `:default` handler writing to stdout, which Docker captures (`docker compose logs`). Nothing is stored or indexed; there is no error tracker, no Sentry, no AppSignal in `mix.exs`.

### 1.2 Supervision tree (read, `lib/charta/application.ex:10-27`)

`Charta.Supervisor` one_for_one, default intensity (3 restarts / 5 s):
`ChartaWeb.Telemetry` -> `Charta.Repo` -> `DNSCluster` -> `Phoenix.PubSub Charta.PubSub` -> `Registry Charta.BoardRegistry` (unique) -> `Registry Charta.SpaceHere` (duplicate) -> `DynamicSupervisor Charta.BoardSupervisor` -> `Charta.AgentKeys` -> `ChartaWeb.Endpoint`.
Hologram starts its own application (`deps/hologram/lib/hologram/application.ex`): SSE, subscription registry, tombstone, gossip.

Long-lived processes that can fail on their own (no request around them):
- `Charta.Board.Server` (`lib/charta/board/server.ex:33-56`), one GenServer per open board under `Charta.BoardSupervisor`, `trap_exit` (`:39`), loads from Postgres in `init`, persists on a 2 s timer or every 500 ops (`:456-470`). A crash here = `GenServer terminating` crash report + a supervisor child report; the tabs reconnect. **The lib gets this free from the logger handler.**
- `Charta.Note.Server` (`lib/charta/note/server.ex:46`), same shape for live notes (ADR 0016), also under `Charta.BoardSupervisor` (`lib/charta/notes.ex:475`).
- Fire-and-forget `Task.start` for indexing (`lib/charta/board/server.ex:477-485`): unlinked, unsupervised, rescues and `Logger.warning`s. `$callers` = the board server pid, so a breadcrumb chain can link it back.
- `Charta.AgentKeys` (GenServer/ETS for agent keys).
- Hologram SSE processes, one per open tab, `max_heap_size` with `kill: true, error_logger: true` (`deps/hologram/lib/hologram/realtime/sse.ex:471-483`), cap raised to 32M words by `config/config.exs:21`. A kill emits an OTP `max_heap_size` error report (a process killed by the VM, no exception): **a failure kind the lib must recognise by report shape, not by exception.**

`ChartaWeb.Telemetry` (`lib/charta_web/telemetry.ex:10-18`) runs `:telemetry_poller` every 10 s but has **no reporter** (ConsoleReporter commented out): the metrics list (`phoenix.router_dispatch.exception.duration`, `vm.memory.total`, run queues) is computed by nobody. The poller's VM measurements are free system-health breadcrumbs the lib can attach to (`[:vm, :memory]`, `[:vm, :total_run_queue_lengths]`).

### 1.3 Endpoint and router (read)

`lib/charta_web/endpoint.ex:23-64`: `Plug.Static` x2 -> (dev) `Phoenix.CodeReloader` -> `Plug.RequestId` -> `Plug.Telemetry [:phoenix, :endpoint]` -> `ChartaWeb.Plugs.Parsers` (own wrapper with a `rescue`, `lib/charta_web/plugs/parsers.ex:14`) -> MethodOverride, Head, Session -> `:capability_headers` -> **`Hologram.Router`** -> `ChartaWeb.Router`. Adapter Bandit (`config/config.exs:26`).

Consequence: Hologram's command and page requests run inside `ChartaWeb.Endpoint.call/2`, so Phoenix's `RenderErrors` wrapper and Bandit's own crash logging see a raising Hologram command exactly like a raising controller. `Plug.RequestId` runs before Hologram, so `request_id` is in Logger metadata for Hologram requests too. A `use Plug.ErrorHandler`-style or `Phoenix.Endpoint` wrapper in the lib would therefore cover Hologram with no Hologram dependency (agent 05 should prove it in the lab).

Router (`lib/charta_web/router.ex`): pipelines `:api` (accepts json/svg/md), `:agent` (`ChartaWeb.Plugs.AgentAuth`), `:space` (`SpaceAuth`), `:tab`. `/api/*` has a catch-all `match :*, "/*path", DocsController, :no_route` (`:268-271`), so an unknown API route is a 404 JSON answer, not a `Phoenix.Router.NoRouteError` (one "expected" error the lib never sees for /api; it does see NoRouteError for every other path).

User-facing errors: `ChartaWeb.ErrorHTML` (`lib/charta_web/controllers/error_html.ex:11-13`): 404 = "There is nothing at this address.", anything else = "1charta had trouble. Try again in a minute." No request id or reference on the page: a user or an agent **cannot quote an error id** today. `ChartaWeb.ErrorJSON` (`error_json.ex:12-19`): `{error: "internal_server_error", hint, docs}`, also no id. Proposal: put the event id (or `request_id`) in both, e.g. `ref: "..."`.

### 1.4 Hologram, server side (read, deps/hologram 0.11.1 from hex, patched by `lib/mix/tasks/hologram.patch.ex` + `patches/hologram-*.patch`, JS only)

- Actions run **in the browser** (compiled Elixir -> JS). An action that raises is a JS exception, never a BEAM error. Server-side are: page `init/3` on first GET, **commands** (`module.command/3`), middleware, SSE.
- `Hologram.Controller.handle_command_request/1` (`deps/hologram/lib/hologram/controller.ex:242-400`) calls `module.command(name, params, server)` at `:355` with **no rescue**: a raising command crashes the Bandit request process -> 500 via the endpoint -> Bandit/Phoenix log it. The client turns any non-2xx into `HologramRuntimeError("command failed: <status>")` (`deps/hologram/assets/js/client.mjs:181-182, 228-230`).
- **Silent failure 1:** if the command's next action cannot be encoded, `Encoder.encode_term` returns non-ok, the server answers **200 with `status: 0`** (`controller.ex:380-381`) and logs nothing; the client throws `command failed: <action>` (`client.mjs:193-195`). Only the browser sees it. The lib can only catch this via the browser path (1.6) or a Hologram telemetry hook that does not exist.
- CSRF / instance-id mismatches: `Logger.warning` + 403 (`controller.ex:274, 282`), no exception.
- Page param errors: `reraise Hologram.ParamError` (`deps/hologram/lib/hologram/page.ex:124-129`).
- `Hologram.Realtime.SubscriptionRegistry` logs a multi-line `Logger.warning` when no connection attached in time (`subscription_registry.ex:659-669`): noisy, not an error, but carries inspected ids. Worth a default "ignore/downgrade" rule.
- Hologram's only telemetry is the compiler (`[:hologram, :compiler, :start|:stop]`, `lib/mix/tasks/compile/hologram.ex:99, 217`): **no runtime telemetry events** for commands or pages. The lib sees Hologram requests through `[:phoenix, :endpoint, ...]` (Plug.Telemetry) and Bandit's `[:bandit, :request, :exception]`, not through anything Hologram-specific.
- Client-side runtime: `deps/hologram/assets/js/logger.mjs` writes debug logs to `sessionStorage["hologram_logs"]`; `error_overlay.mjs` shows runtime errors in a dismissable overlay (dev). Neither reaches the server.
### 1.5 Swallowed and downgraded errors in 1charta's own code (read)

`grep -rn -E "rescue|catch" lib` finds 17 sites. None re-reports; four log at warning, one at error:

| site | what is swallowed | visible? |
|---|---|---|
| `lib/charta/board/server.ex:438-442` | `Store.append_event` raising while recording a refusal/tab error | `Logger.warning` (message only, no stacktrace) |
| `lib/charta/board/server.ex:477-485` | `Notes.index_board` in an unlinked `Task.start` | `Logger.warning`, no stacktrace |
| `lib/charta/notes.ex:932-936` | same indexing, inline | `Logger.warning`, no stacktrace |
| `lib/charta_web/controllers/file_controller.ex:157-159` | S3 put failing | `Logger.error` with `inspect(reason)`, 502 to client |
| `lib/charta/files/s3.ex:38,42` | S3 GET non-200 / transport error | `Logger.warning` |
| `lib/charta/boards.ex:13-21` | `:exit` from `GenServer.call(:snapshot)` (board stopping) | silent, falls back to the store (intended) |
| `lib/charta/boards.ex:135-141`, `lib/charta/notes.ex:480-486` | `:exit {:noproc,_}` retried 5x with 20 ms sleeps | silent; a 6th failure exits the caller (then visible) |
| `lib/charta/spaces.ex:839-848, 1077-1097` | **any** `Postgrex.Error` on rename -> `{:error, :taken}` | silent; a DB outage reads as "name taken" |
| `lib/charta/participants.ex:125-128` | `Postgrex.Error` unique_violation -> `:taken` (others re-raised?) | check the else branch |
| `lib/charta/passkeys.ex:724-731`, `links.ex:543`, `grants.ex:581` | any exception in key decode / signature verify -> `false`/`:error` | silent (intended: a bad signature is not an error) |
| `lib/charta/access.ex:133, 241`, `api/grants_controller.ex:370` | no session fetched / bad query -> nil | silent (intended) |
| `lib/charta_web/plugs/parsers.ex:12-25` | `Plug.Parsers.ParseError` under `/api` -> 400 JSON; elsewhere re-raised | 400 is intended; the lib should see it only as a 4xx breadcrumb |

Takeaways for the lib: (a) the warnings carry `Exception.message(e)` but drop the stacktrace, so a `Blackbox.capture_exception(e, __STACKTRACE__, level: :warning)` one-liner (or a `rescue` macro) is what these sites want; (b) the two `rescue Postgrex.Error` renames are the kind of silent bug 1charta has (DB down = "taken"); a trace session cannot distinguish intended from unintended rescues, so the fix is at the site, not in the tracker; (c) the 5x retry loops are the "what happened before" the lib should record as breadcrumbs (a `:noproc` exit caught 5 times, then the crash).

### 1.6 Browser errors already reach the server (read) - a mini tracker exists

1charta already ships a small error tracker for the board page's JavaScript (ADR 0010):
- `priv/static/assets/board.js:5921-5948`: `window` `error` + `unhandledrejection` -> `reportError` -> `POST /tab/error` with `{key, me, name, message, stack}`, keepalive, max 20 distinct per tab (dedup by `name|message|stack`), and on a sealed board (`hashKey()`) the message is dropped and only same-origin frames are sent (content must not leak).
- `lib/charta_web/router.ex:27` -> `ChartaWeb.TabController.error/2` (`tab_controller.ex:57-75`): caps name 100, message 1000, stack 4000, UA 300; needs a valid board key (401 otherwise).
- `Charta.Boards.tab_error/3` (`boards.ex:90-91`) casts to the board server, which rate-limits all "noise" to **60 per board per minute** (`board/server.ex:30-31, 419-436`) and appends a `tab_error` row to `board_events`.
- `Charta.Store.prune/1` (`store.ex:183-197`) deletes `ops_rejected` and `tab_error` rows older than **30 days** on each board server start.
- **Nobody reads them** except by SQL (`test/charta_web/tab_error_test.exs`, `test/e2e/sidecar.mjs:138`): no API route, no UI, no grouping. Hologram's own runtime errors on non-board pages (Home, Changelog, Space pages) are not reported at all.

This is the seed of the JS side of the lib's event model: same caps, same sealed-board rule, same per-source rate limit. The lib should take these rows over (a `source: :browser` event) rather than keep a second store.

### 1.7 The agent API and the sidecar: how failures reach an agent today (read)

- Agent API: `/api/v1/*` behind `ChartaWeb.Plugs.AgentAuth` (`lib/charta_web/plugs/agent_auth.ex`), keyed **per board** (`ck_`/`cp_`, `Charta.AgentKeys`), level from `Charta.Access.level/2`. There is **no operator/admin key**; prod ops are `just` recipes over ssh (`justfile:27-107`, ADR 0024). So an "errors" API has no existing auth to reuse: it needs its own (an env-provided operator token in prod, open on localhost in dev).
- Error shape to agents: `{error: <code>, hint: <sentence>}` everywhere (ADR 0022 §C6; `ChartaWeb.ErrorJSON`, `Plugs.Parsers`, the `/api` catch-all). Refused ops are kept as `ops_rejected` board events (`board/server.ex:410-417`), again only readable by SQL.
- The sidecar (`sidecar/`, Rust, 11.8k lines, ADR 0012/0017) turns a board or Space into a directory. Failures reach the agent as **files**: `shapes/<id>.rejected.json` / `board.rejected.json` with the reason (`sidecar/src/main.rs:866, 1247-1252`), an append-only `.charta/log` (`main.rs:362-366`), cell failures written onto the shape as `out.error {text, at, by}` (`sidecar/src/cell.rs:463-484`), and `hint` over `error` when printing a refusal (`api.rs:248-258`). Agents (Claude Code) already work by reading files the sidecar writes. That is the natural third door for errors: a directory of Markdown/JSON issue files (see section 7).

### 1.8 Version stamp (read)

`Charta.build/0` (`lib/charta.ex:11`) = `BUILD_SHA` build arg (Dockerfile, CI) or boot time in dev (`config/runtime.exs:38-42`). The board page already sends it on heartbeats (`board_page.ex:5579`). That is the release tag every event should carry, and the "first seen in build X / regressed in build Y" key.

## 2. erl_crash.dump
Read with `head`, `grep`, a Python decode of the slogan; the file was not modified. Raw output in `logs/07-crashdump.log`. **verified** (read by me).

- File: `/Users/lennartbuttner/Projects/1charta/erl_crash.dump`, 7,100,932 bytes, 229,610 lines, mtime 2026-09-20 15:49, git-ignored (`.gitignore:17`).
- Header: `=erl_crash_dump:0.5`, `Sun Sep 20 15:49:58 2026`, `Erlang/OTP 28 [erts-16.4.0.6] ... [smp:11:11] [jit]`, `Taints: crypto`, 31,185 atoms, memory total 81.9 MB (processes 18.5 MB, binary 5.7 MB, code 19.8 MB, ets 2.0 MB), 244 processes, 25 ports, 129 ETS tables.
- Slogan: `Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,[<<...>>]` - the binary is the text Elixir tried to print, decoded:

```
** (EXIT from #PID<0.94.0>) exited in: GenServer.stop(#PID<0.381.0>, :normal, :infinity)
    ** (EXIT) exited in: :sys.terminate(#PID<0.381.0>, :normal, :infinity)
        ** (EXIT) an exception was raised:
            ** (ErlangError) Erlang error: :terminated:

  * 1st argum          <- erts cuts the slogan here (1032 chars)
```

- What was running: `Mix.Tasks.Test`, `ExUnit.Server`, `ExUnit.CaptureServer`, the full `Charta` tree (Repo with 22 Postgrex connections, Endpoint, PubSub, BoardRegistry, SpaceHere) and exactly one test module, `Charta.MembersTest`. So: **a `mix test test/charta/members_test.exs` in the repo root on 2026-09-20 at 15:49**, between commits 836d9e9 (14:24, ADR 21 proposed) and 8634235 (20:03, ADR 0021 steps 0-3a): an agent session building ADR 0021's people step.
- Why it died: there is no process named `user` or `standard_error` left in the dump (only `user_drv_reader`): the VM's IO server was already gone. An IO call on a dead device raises `ErlangError :terminated`; that happened inside a GenServer's `terminate` during `GenServer.stop(pid, :normal)` at the end of the run; Elixir then tried to print that exit to `standard_error`, which also no longer existed -> `badarg` in `io:put_chars` -> since a Mix task runs inside init's boot, erts halts with "Runtime terminating during boot" and writes the dump. The most likely trigger is the controlling pipe going away (a tool call killed on timeout or an output pipe closed early), not a 1charta bug. **Nothing on prod.** (Inference from the dump; the exact killer of the IO server is unknown.)

What this teaches the lib:
1. A crash dump is the only witness of a VM-level halt (slogan, time, OTP version, memory, process list). "Read the last `erl_crash.dump` on boot and file it as an event" is worth doing, but only the header (first ~40 lines + `=memory`) and process counts: this small test VM wrote 7 MB; a prod dump can be GBs. Stream, never `File.read!`.
2. The slogan is truncated by erts (here at 1032 chars) and embeds Erlang terms with binaries as `<<42,42,32,...>>`: decode byte lists to text for display.
3. Dedupe by (path, mtime, size) and move/rename after import, or it is re-reported every boot. Point `ERL_CRASH_DUMP` at a known path in the release (the Dockerfile sets none, see 4), otherwise the dump lands in the container's cwd and dies with the container.
4. Dev dumps from `mix test` should be ignored or tagged `env: :test`; this one would have been noise.

## 3. Prod reality
Read-only over ssh, counts only, 2026-09-27 ~09:06 UTC. Raw output: `logs/07-prod.log`. **verified**.

- `docker compose logs --since 168h app` returned only **3,683 lines**, all `[info]`: 0 warning, 0 error. The reason is not a quiet week: the `app` container was **created 2026-09-27 07:37 UTC** (today's deploy, `restarts=0`) and `docker compose logs` only shows the current container. **Every deploy throws the log history away.** On top, `deploy/compose.yaml` caps the json-file log at 5 x 10 MB on purpose ("a free board's secret is in its request path", ADR 0023 §1).
- What 90 minutes of prod log is: `Sent 200 in N` (1,746), `POST /tab/cursor` (548), `GET /api/v1/th...` (319), `GET /api/v1/bo...` (299), `POST /hologram` (252), `HEAD /hologram` (223), migrations on boot (23+23). Request lines are the bulk; they are breadcrumbs, not errors.
- **Consequence for 1charta: there is no error history in prod at all today.** Any error from last week is unknowable. This is the strongest argument for storage in the app's own Postgres (survives deploys) over stdout.
- **Privacy constraint (hard):** request paths carry board secrets (`/b/<id>`, `?key=ck_...`). Phoenix's request log already prints `GET /b/...` paths; the lib must scrub paths (board ids) and query keys before it stores a breadcrumb, not only params.
- Counting the `tab_error` / `ops_rejected` rows in the prod database was refused by the permission classifier; skipped, not retried. Unknown how many browser errors prod holds.

## 4. Dockerfile and release
`Dockerfile` (read):
- Builder `hexpm/elixir:1.20.4-erlang-28.5.0.6-debian-trixie-20260824-slim`, runner `debian:trixie-20260824-slim`; `.tool-versions`: elixir 1.20.4-otp-28, erlang 28.5.0.6. So **OTP 28.5** in prod: the OTP 27+ `:trace` session API, `Process.set_label/1` (27) and `:logger` handler API are all available; the dev dump says erts-16.4.0.6 (same OTP line).
- Build order: `COPY mix.exs mix.lock` -> `mix deps.get --only prod` -> apply `patches/` to Hologram -> `COPY config/config.exs config/prod.exs` -> `mix deps.compile` -> `COPY priv`, `COPY lib` -> `mix compile` (Hologram writes bundles) -> `COPY config/runtime.exs` -> `COPY rel` -> `mix release`.
- The runner stage copies **only** `_build/prod/rel/charta`: **no source files in the image**. Stacktraces carry `file: ~c"lib/charta/board/server.ex", line: 441` but the file is not there. Source context needs either a build step that packs `lib/**/*.ex` into the release (Sentry's `mix sentry.package_source_code` pattern, into `priv/`), or the event keeps `(build_sha, file, line)` and the reader (UI or agent) resolves the line against the repo at that sha. 1charta's agents have the checkout; the second is free and exact.
- `BUILD_SHA` is a build arg set by CI (`.github/workflows/ci.yml:153`, `github.sha`) and exported as env in the runner (Dockerfile end) -> `Charta.build/0`. Release version stays `0.1.0` (`mix.exs:7`); the sha is the useful version.
- No `releases:` block in `mix.exs` (default release), `extra_applications: [:logger, :runtime_tools]` (`mix.exs:24`), `start_permanent: true` in prod (a top supervisor giving up halts the VM). No `ERL_CRASH_DUMP`, `ERL_CRASH_DUMP_SECONDS`, `+Bd` etc.: a crash dump in prod lands in the container's cwd `/app/erl_crash.dump` owned by `nobody` and is lost when the container is recreated. `rel/overlays/bin/server` is `PHX_SERVER=true exec ./charta start`; compose runs `bin/migrate && exec bin/server` so the BEAM is PID 1 and gets SIGTERM (`deploy/compose.yaml`), with a 30 s stop grace for board saves.
- `.dockerignore` excludes `/test/`, `/_build/`, `/deps/`, `/docs/`, `erl_crash.dump` (root-anchored).

## 5. Packaging a path dep in this repo
All **read** from source; nothing compiled (the brief forbids mix in the root).

### 5.1 Where

The repo root today: `lib/`, `assets/`, `sidecar/` (Rust, its own build), `patches/`, `rel/`, `deploy/`, `docs/`. There is no `packages/` yet. Proposal: **`packages/blackbox/`** (a full Mix project: own `mix.exs`, `lib/`, `test/`, `README.md`, `CHANGELOG.md`, `LICENSE`), wired as

```elixir
# mix.exs deps
{:blackbox, path: "packages/blackbox"}
```

Why `packages/` and not top level beside `sidecar/`: the name says "extractable"; `git subtree split --prefix packages/blackbox` or `git filter-repo --subdirectory-filter` gives the hex repo its history later; a second package (e.g. a UI) has a home.

### 5.2 What Mix, Phoenix, Hologram and `mix release` do with it (read)

| concern | behaviour | source | action |
|---|---|---|---|
| Recompile on change | Mix checks path deps for staleness on every `mix compile` and recompiles them (unlike hex deps) | Mix docs, `Mix.Dep` (read) | none |
| Dev code reloading | `Phoenix.CodeReloader` reloads only `reloadable_apps`, default `[Mix.Project.config()[:app]]` = `[:charta]` | `deps/phoenix/lib/phoenix/code_reloader/server.ex:116, 177-183`; docs `code_reloader.ex:24-30` (Phoenix 1.8.13) | set `reloadable_apps: [:charta, :blackbox]` on the endpoint in `config/dev.exs`, or edits in the lib need a server restart |
| Hologram's compiler | `Hologram.Reflection.list_elixir_modules/0` takes **every module of every loaded OTP app** (minus `:hex`) into its IR and call graph (`deps/hologram/lib/hologram/reflection.ex:341-359, 735-755`); only modules reachable from pages/components are transpiled to JS | read | the lib's modules will be in the call graph (as Phoenix's and Ecto's are). **Never call the lib from a Hologram action** (actions run in the browser: `:logger`, `:ets`, `:persistent_term` calls cannot be transpiled or will fail at runtime); call it from commands and server code only. A lib change changes module digests, so Hologram rebuilds its call graph (the memory notes on stale `call_graph.bin`/`module_digest.plt` apply) |
| Hologram dependency | the lib must not depend on `:hologram` (BRIEF); nothing in 1.2-1.4 needs it: Hologram requests go through the Phoenix endpoint, Bandit and Plug.Telemetry | read | 1charta-specific glue (e.g. mapping a Hologram command to a route name) lives in 1charta, not in the lib |
| `mix release` | a path dep is an ordinary dependency app: compiled into `_build/prod/lib/blackbox` and included in the release with its `priv/` | Mix release docs (read) | none |
| **Dockerfile** | `COPY mix.exs mix.lock` then `mix deps.get`: **the path does not exist in the builder yet, so `deps.get` fails** | `Dockerfile` build order | add `COPY packages packages` before `mix deps.get` (costs the deps layer cache on every lib edit; acceptable) |
| `.dockerignore` | `/_build/`, `/deps/` are root-anchored: `packages/blackbox/_build` and `/deps` would be sent into the build context | `.dockerignore` | add `packages/*/_build`, `packages/*/deps` |
| `.gitignore` | same for git | `.gitignore` | add the same two lines |
| Tests | root `mix test` (and CI `ci.yml:61`) does not run the package's tests | read | the package has its own `mix test` in `packages/blackbox` with its own `_build`; a `just blackbox-test` recipe and one CI step. Running it never touches Hologram bundles (no hologram dep, separate `_build`), so it is safe beside a running dev server, unlike root `mix test` (memory: hologram-bundles-shared-across-envs) |
| Formatter | root `.formatter.exs` inputs will not cover `packages/` | read | the package keeps its own `.formatter.exs` |
| Config | the lib reads `Application.get_env(:blackbox, ...)`; 1charta sets it in `config/*.exs` / `runtime.exs` like any dep | - | keep the lib's config small: repo, env, release (`Charta.build/0`), scrub list |
| Optional deps | the lib attaches to Phoenix/Plug/Bandit/Ecto/Oban telemetry by **event name** with `:telemetry.attach_many`; only `:telemetry` is a hard dep. `ecto_sql`/`postgrex` optional (Postgres store), `plug` optional (a Plug for the UI/API), `jason` optional (JSON on OTP 27+ can use `:json`) | - | `{:ecto_sql, "~> 3.10", optional: true}` etc. and `Code.ensure_loaded?` guards |
| Hex later | swap `path:` for `"~> 0.1"`; `package: [files: ~w(lib priv mix.exs README.md LICENSE CHANGELOG.md)]` | - | the in-repo package must not `import` anything from `Charta` (a CI grep can enforce it) |

### 5.3 How 1charta wires it in (proposal)

1. `mix.exs`: `{:blackbox, path: "packages/blackbox"}`.
2. `Charta.Application`: `{Blackbox, repo: Charta.Repo, release: Charta.build(), env: config_env}` as the **first** child after `ChartaWeb.Telemetry` and `Charta.Repo` (the logger handler should be installed before the Endpoint so boot crashes are seen; the writer needs the Repo; a handler that is installed earlier, in `Application.start/2` before `Supervisor.start_link`, buffers to ETS until the writer is up).
3. A migration in `priv/repo/migrations` generated by `mix blackbox.gen.migration` (ErrorTracker/Oban pattern: the lib ships versioned `up/down` functions, the app owns the migration file).
4. `config/config.exs`: `config :blackbox, scrub_params: ["password", "key"], scrub_paths: [~r{^/b/[^/]+}, ...]` (reuse `:phoenix, :filter_parameters`).
5. `ChartaWeb.ErrorHTML` / `ErrorJSON`: add the event id (`ref`) to the page and the JSON, so a person or an agent can quote it.
6. The existing `/tab/error` path (1.6) calls `Blackbox.capture(:browser, ...)` in addition to or instead of writing `tab_error` rows.

## 6. Hex name availability
`curl https://hex.pm/api/packages/<name>`, 2026-09-27; 404 = no such package, 200 = taken. Control: `phoenix` -> 200. Raw: `logs/07-hex.log`. **verified**.

| name | hex.pm | note |
|---|---|---|
| **blackbox** | **free (404)** | working name; GitHub `language:elixir` has one 0-star repo `etori-sangiacomo/blackbox` (2023). Outside Elixir, "blackbox" is StackExchange's well-known git-secrets tool: search noise, no clash on hex |
| black_box | taken | 0.1.0 (2018), "Simple API wrapper for http://blackbox.co.ke", 1,600 downloads, dead. Hex has no confusable-name rule that I know of; whether hex.pm would refuse `blackbox` beside `black_box` is **unknown** (probably not) |
| flight_recorder | free | long; says exactly what it is. GitHub: nothing Elixir by that name |
| flightrecorder | free | |
| postmortem | free | |
| post_mortem | free | |
| tombstone | free | clashes in 1charta's own head: Hologram has `Hologram.Realtime.Tombstone` (`deps/hologram/lib/hologram/realtime/tombstone.ex`) |
| autopsy | free | |
| aftermath | free | |
| crashlog / crash_log | free | |
| wreckage | free | |
| epitaph | free | |
| coroner | free | |
| last_words / lastwords | free | cute, but the lib records more than the last words |
| witness | taken | 2.0.0, 2026-07-22, structured logging lib |
| error_tracker, tower, sentry | taken | the incumbents (control) |
| fdr, recorder, beamtrail, errorlog, blackbox_ex, crash_report, flight_deck | free | |

Verdict: **`blackbox` is free on hex** and fits the brief's flight-recorder idea; module `Blackbox`. Reserve it early by publishing a 0.0.1 placeholder only when the user says so (outward-facing). Fallback: `flight_recorder`.

## 7. How coding agents would read and resolve errors
What exists: agents work through `/api/v1` (JSON, `{error, hint}`), the sidecar's files (`.rejected.json`, `.charta/log`, cell `out.error`), and in dev the local server's stdout. ADR 0012 (`docs/adr/0012-a-board-as-a-directory.md:177-180, 258-263`) already chose **files over an MCP server** for boards: "products ship MCP servers when they have no local representation"; "Not an MCP server: it wraps the API in tool calls, which the API already is; files are different in kind (grep, diff, git, the agent's own skills)". The same reasoning applies to errors. There is no operator key; prod reads by Claude are blocked by the permission classifier today (section 3), so prod errors reach an agent only through a door the user explicitly allows.

Proposal, three doors over one store, in order of value:

1. **HTTP JSON API** in the lib, mounted by the app (`forward "/_blackbox", Blackbox.Plug`): `GET /issues?status=unresolved&since=<build>` (grouped, counts, first/last seen, first build), `GET /issues/:id` (latest occurrence + breadcrumb timeline), `GET /issues/:id.md` (the same as Markdown, the agent's best format), `POST /issues/:id/resolve {build: "<sha>"}` (resolved in; a later occurrence in a newer build = regression, reopens), `POST /issues/:id/ignore`, `POST /issues/:id/note`. Auth: dev = localhost only; prod = a bearer token from env (`BLACKBOX_TOKEN`), separate from board keys. One URL + one token is also what a user can allow in their agent's permission rules.
2. **Files in dev** (optional, off in prod): the dev server writes `tmp/blackbox/<issue>.md` (git-ignored, the repo already ignores `/tmp/`): title, count, build, stacktrace as `lib/charta/board/server.ex:441` (repo-relative, so Claude Code makes them clickable and can open them), the breadcrumbs, the scrubbed state. An agent greps a directory it already has; no tool needed. Resolution stays through the API (a file edit is not a decision).
3. **MCP**: a thin wrapper over (1) only if a user needs it for an agent without shell/HTTP (claude.ai). Not first, per ADR 0012's reasoning. (Sentry ships an MCP server; that it is useful for a hosted SaaS says nothing for a self-hosted lib whose store the agent can reach directly.)

Rules for agent-readable events: stack frames as `path:line` relative to the project root; the build sha on every occurrence (the agent can `git show <sha>:<path>` for the exact source, which covers source context without shipping sources, section 4); the `{error, hint}` shape for API errors; no secrets or board content (section 3, finding F6); stable ids an agent can put in a commit message ("fixes blackbox#a1b2c3") so `resolve` can later be automated from git log.

## Findings table
| id | what | evidence | priority | proposal in one line | size |
|---|---|---|---|---|---|
| F1 | Prod keeps no error history: stdout only, container recreated on every deploy, 50 MB cap | section 3; `deploy/compose.yaml` logging; container created 2026-09-27 07:37 | P0 | store events in the app's Postgres (survives deploys), not logs | M |
| F2 | No error id anywhere a person or agent can quote | `error_html.ex:11-13`, `error_json.ex:12-19` | P0 | put the event id (`ref`) in ErrorHTML and ErrorJSON | S |
| F3 | Board secrets live in request paths and `?key=` | `compose.yaml` comment, `config.exs:42-43`, `router.ex` `/b/...` | P0 | scrub paths by pattern and query keys before storing any breadcrumb; reuse `:filter_parameters` | S |
| F4 | GenServer state in crash reports = the whole board (user text), no `format_status/1`, no Inspect derive | `lib/charta/board/server.ex:46-55`; `grep format_status lib` = 0 | P0 | the lib truncates and redacts state by default; 1charta adds `format_status/1` to Board.Server and Note.Server | S |
| F5 | A browser error tracker already exists but is write-only (rows read by SQL only) | `board.js:5921-5948`, `tab_controller.ex:57-75`, `board/server.ex:419-436`, `store.ex:183-197` | P1 | route `/tab/error` into the lib as `source: :browser`; keep the 60/min cap and sealed-board rule | S |
| F6 | Warnings in rescues drop the stacktrace | `board/server.ex:441, 482`, `notes.ex:935` | P1 | `Blackbox.capture_exception(e, __STACKTRACE__, level: :warning)` at those three sites | S |
| F7 | `rescue Postgrex.Error -> {:error, :taken}` hides DB outages as "name taken" | `spaces.ex:846-847, 1095-1096` | P2 | 1charta fix: match `unique_violation` only, as `participants.ex:125-129` does; the tracker cannot see this | S |
| F8 | Hologram command encode failure: 200 + `status: 0`, no log on the server | `deps/hologram/lib/hologram/controller.ex:380-381`, `client.mjs:193-195` | P2 | only visible via the browser path (F5); report upstream to Hologram | S |
| F9 | Hologram has no runtime telemetry; its requests are seen via Plug.Telemetry/Bandit only | `grep :telemetry deps/hologram/lib` = compiler only | P2 | the lib stays Hologram-free; name Hologram routes from `conn.path_info` (`/hologram/command`) in 1charta glue | S |
| F10 | SSE processes die by `max_heap_size` kill (VM error report, no exception) | `deps/hologram/lib/hologram/realtime/sse.ex:471-483` | P1 | the handler must parse the OTP `max_heap_size` report as its own failure kind | S |
| F11 | Crash dumps: none configured in prod; the dev dump is a killed `mix test`, 7 MB, slogan truncated at 1032 chars with binaries as byte lists | section 2 | P2 | set `ERL_CRASH_DUMP` to a volume; import only the header on boot; decode `<<..>>` | M |
| F12 | No source files in the release image | `Dockerfile` final stage | P2 | keep `(build_sha, file, line)`; source context from the repo at the sha; packing sources optional | S |
| F13 | Path dep breaks the Docker build as written | `Dockerfile` `COPY mix.exs mix.lock` then `deps.get` | P0 (for step 1) | `COPY packages packages` before `mix deps.get`; ignore `packages/*/_build,deps` | S |
| F14 | Dev reloader ignores path deps | `phoenix/code_reloader/server.ex:116, 177-183` | P1 | `reloadable_apps: [:charta, :blackbox]` in `config/dev.exs` | S |
| F15 | Hologram puts every loaded app's modules in its call graph | `hologram/reflection.ex:341-359, 735-755` | P1 | never call the lib from actions (client code); commands and server only | S |
| F16 | `telemetry_poller` runs with no reporter; `Logger` primary level `:info` in prod | `telemetry.ex:10-18`, `prod.exs:18` | P2 | the lib can use `[:vm, ...]` poller events as health breadcrumbs; debug breadcrumbs need the lib's own capture below the primary level (agent 06) | S |
| F17 | No operator/admin auth in the app; prod reads by agents need explicit user permission | `agent_auth.ex`, `justfile:27-107`, section 3 | P1 | own bearer token from env for the errors API; localhost-only in dev | S |
| F18 | Name `blackbox` free on hex; `black_box` taken (dead, 2018) | section 6 | - | take `blackbox`; fallback `flight_recorder` | S |

## Recommendations for the lib
1. **Put it at `packages/blackbox/`** as a standalone Mix project with its own `_build`, `deps`, `test`, `.formatter.exs`; 1charta depends on it with `path:`. Add `COPY packages packages` before `mix deps.get` in the Dockerfile, `packages/*/_build` and `packages/*/deps` to `.gitignore` and `.dockerignore`, `reloadable_apps: [:charta, :blackbox]` in `config/dev.exs`, a `just blackbox-test` recipe and one CI step. No `import Charta` or `Hologram` anywhere in the package (CI grep).
2. **Hard deps: `:telemetry` only.** `ecto_sql`/`postgrex`, `plug`, `jason` optional. Attach to framework telemetry by event name, so Phoenix, Bandit, Oban, Ecto are optional too.
3. **Store in the app's own Postgres** (issues + occurrences, 1charta's `Charta.Repo`), with retention (30 days, like `Store.prune/1` does for `tab_error`). Stdout is gone at every deploy (F1).
4. **Every event carries the build** (`release: Charta.build()` = `BUILD_SHA`), and `file:line` repo-relative; source context comes from the repo at that sha for agents and the UI. Offer `mix blackbox.package_source` only as an option (F12).
5. **Privacy by default:** scrub `filter_parameters`, configurable path patterns (`/b/<id>`), query keys; truncate and redact GenServer state and last message (a limit in bytes, `inspect(limit:, printable_limit:)`), honour `format_status/1`. 1charta adds `format_status/1` to `Charta.Board.Server` and `Charta.Note.Server` (F4). Never store a sealed board's content: the browser rule in `board.js:5928-5931` is the model.
6. **Browser errors are a source** (`source: :browser`): 1charta's `/tab/error` feeds the lib; same caps (100/1000/4000 chars), per-board rate limit, dedupe by `name|message|stack` (F5). Extend it to Hologram's non-board pages later.
7. **Recognise OTP report shapes without exceptions**: `max_heap_size` kills (Hologram SSE, F10), supervisor child terminations, `:noproc` exits after retries (1.5).
8. **A one-line capture API for rescues**: `Blackbox.capture_exception(e, __STACKTRACE__, level: :warning, extra: %{})`; apply it at the three `Logger.warning` rescue sites (F6).
9. **An id people and agents can quote**: expose `Blackbox.current_ref/0` (per request, the `request_id` or the event id) and put it in `ChartaWeb.ErrorHTML` and `ErrorJSON` (F2).
10. **Agent access, three doors over one store:** a JSON + Markdown API mounted with `forward` (list, show, `.md`, resolve-in-build, ignore, note), a dev-only directory of Markdown issue files under `tmp/blackbox/`, an MCP wrapper last (ADR 0012's files-over-MCP reasoning). Prod API behind its own env token; the user decides whether an agent may use it (F17).
11. **Crash dumps**: set `ERL_CRASH_DUMP=/app/data/erl_crash.dump` on a volume in `deploy/compose.yaml`; on boot the lib streams the header (slogan decoded, time, OTP, memory, process count) into one event and renames the file (F11).
12. **Do not call the lib from Hologram actions** (browser code); document it in the lib's README for Hologram users (F15).
13. **Name: `blackbox`** (free on hex, 2026-09-27). Publish a placeholder only when the user decides to (outward-facing).

## Sources

All local paths are in `/Users/lennartbuttner/Projects/1charta` at HEAD `b4d1c71` (working tree of 2026-09-27), **read** unless marked.

- Logger/config: `config/config.exs:21-43`, `config/dev.exs:27,58`, `config/prod.exs:18`, `config/test.exs:28`, `config/runtime.exs:27-42`
- Tree/processes: `lib/charta/application.ex:10-27`, `lib/charta/board/server.ex:24-56, 173-174, 204-207, 410-485`, `lib/charta/note/server.ex:46`, `lib/charta/notes.ex:474-486, 926-937`, `lib/charta/boards.ex:13-21, 90-91, 135-141`, `lib/charta_web/telemetry.ex:10-18`
- Web: `lib/charta_web/endpoint.ex:23-64`, `lib/charta_web/router.ex:1-60, 268-271`, `lib/charta_web/controllers/error_html.ex`, `error_json.ex`, `tab_controller.ex:53-78`, `file_controller.ex:157-159`, `lib/charta_web/plugs/parsers.ex`, `lib/charta_web/plugs/agent_auth.ex`
- Swallowed errors: `lib/charta/spaces.ex:839-848, 1077-1097`, `participants.ex:125-130`, `passkeys.ex:724-731`, `links.ex:543`, `grants.ex:581`, `access.ex:133, 241`, `files/s3.ex:38-42`
- Browser: `priv/static/assets/board.js:5919-5948`, `lib/charta/store.ex:183-197`, `docs/adr/0010-event-sourcing.md:29-32`
- Hologram 0.11.1 (hex, patched JS): `deps/hologram/lib/hologram/controller.ex:242-400`, `page.ex:124-129`, `realtime/sse.ex:466-483`, `realtime/subscription_registry.ex:659-669`, `reflection.ex:284-298, 341-379, 735-755`, `lib/mix/tasks/compile/hologram.ex:99, 217`, `assets/js/client.mjs:180-234`, `assets/js/logger.mjs`, `assets/js/error_overlay.mjs`; `lib/mix/tasks/hologram.patch.ex`
- Phoenix 1.8.13: `deps/phoenix/lib/phoenix/code_reloader.ex:13-30`, `code_reloader/server.ex:116, 177-183`
- Sidecar: `sidecar/src/main.rs:362-366, 866, 1247-1252`, `sidecar/src/api.rs:248-258`, `sidecar/src/cell.rs:463-484`; `docs/adr/0012-a-board-as-a-directory.md:177-180, 258-263`
- Release: `Dockerfile`, `.dockerignore`, `.gitignore:2,8,17,23`, `.tool-versions`, `mix.exs:1-78`, `rel/overlays/bin/server`, `deploy/compose.yaml`, `.github/workflows/ci.yml:61,153`, `justfile:1-107`
- Crash dump: `erl_crash.dump` (**verified**, read-only; `logs/07-crashdump.log`); git log 836d9e9, 8634235
- Prod: ssh read-only 2026-09-27 (**verified**, `logs/07-prod.log`); DB counts refused by the permission classifier
- Hex: `https://hex.pm/api/packages/<name>` (**verified**, `logs/07-hex.log`); GitHub `api.github.com/search/repositories?q=<name>+language:elixir`
- WebSearch calls used: 0
