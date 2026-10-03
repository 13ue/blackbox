# Blackbox

A flight recorder for the BEAM. It catches every failure it can see (process
crashes, supervisor reports, Phoenix and Bandit exceptions, `Logger.error`),
keeps what happened before each one (a per-process breadcrumb ring, the
GenServer's last message and state, the caller's crumbs), stores it in the
app's own Postgres, and shows one timeline per failure to people and agents.

No extra services, no public ingest: it runs inside your app. Requires OTP 27+
and Elixir 1.18+.

## Install

```elixir
# mix.exs
{:blackbox, github: "13ue/blackbox"},
{:ecto_sql, "~> 3.10"}, {:postgrex, ">= 0.17.0"}  # for the store
```

Capture starts with the `:blackbox` application, before yours, so boot
failures are seen. Then:

1. **Tables**: `mix blackbox.gen.migration && mix ecto.migrate`.
2. **The store**, in your supervision tree right after the Repo:

   ```elixir
   children = [
     MyApp.Repo,
     {Blackbox, repo: MyApp.Repo, build: System.get_env("BUILD_SHA"), spool_dir: "/data/blackbox"},
     # ...
   ]
   ```

   It opens its own one-connection pool, so it never queues behind your app.
   On shutdown it writes what it holds; what it cannot write goes to
   `spool_dir` and is stored on the next boot.

3. **The page and the API**, in your router:

   ```elixir
   # dev
   forward "/_blackbox", Blackbox.Plug, authorize: &Blackbox.Plug.localhost?/1
   # prod: Basic auth for people (any user name), Bearer for agents
   forward "/_blackbox", Blackbox.Plug, authorize: Blackbox.Plug.token(System.fetch_env!("BLACKBOX_TOKEN"))
   ```

4. **In your app's test env**: `config :blackbox, capture: false`.

## Configure

```elixir
config :blackbox,
  in_app: [:my_app],            # your apps: their frames decide grouping
  backtrace_depth: 32,
  scrub_keys: ["board_key"],    # added to Phoenix's :filter_parameters and the defaults
  scrub_patterns: ["/b/([^:/?#\\s][^/?#\\s]*)"]  # regexes; group 1 is replaced
```

Scrubbing happens before anything is stored or spooled: values under secret
keys (`password`, `token`, `secret`, `authorization`, `cookie`, `api_key`,
`key`, and yours), `key=value` and `key: value` in text, your patterns,
exceptions that print values (`KeyError`, `MatchError`, `Postgrex.Error`
details, `FunctionClauseError` arguments), call messages inside exit reasons,
and the messages in a `:sys` log. **Positional content has no key to match**:
give GenServers that hold user data a `format_status/1` that summarises
`state` and `message`.

## What you add by hand

```elixir
rescue
  e -> Blackbox.capture_exception(e, __STACKTRACE__, context: %{board: id})

Blackbox.capture_message("sync gave up")
Blackbox.crumb("loaded order", %{id: order.id})
Blackbox.set_context(%{tenant: tenant.id})   # also seen by Tasks started here
Blackbox.capture_browser(%{name: n, message: m, stack: s, url: u})  # rate-limit it

# on your error page or JSON error: "Reference a1b2c3-x9k2"
Blackbox.current_ref()
```

## For agents

`GET /_blackbox/api/v1/issues` (JSON), `GET /_blackbox/api/v1/issues/:id.md`
(the issue, its best occurrence and its timeline as Markdown, event text
fenced as data), `GET /_blackbox/api/v1/refs/:ref`. Browser events are left
out unless `source=browser`. `POST .../resolve`, `/mute`, `/reopen` and
`/note` need an `x-blackbox` header. Blackbox never runs anything it reads.

## What it changes globally

- `:erlang.system_flag(:backtrace_depth, 32)` (production default is 8).
- A primary `:logger` filter, `:blackbox_sasl`, first in line. It sees every
  log event (a pattern match, then it passes it on unchanged) and takes OTP's
  crash and supervisor reports before Elixir's translator drops or rewrites
  them. Your console prints exactly what it printed before.
- A `:logger` handler, `:blackbox`, at level `:all`; the primary level still
  decides what arrives. Below `:error`, events become crumbs.
- Telemetry handlers for Phoenix, Plug, Bandit, Finch and your Repo's queries.
- A watchdog puts all of these back if something removes them, and says so;
  `Blackbox.pause/0` and `resume/0` stop it from fighting you.

The costs, measured: about 0.4-0.7 µs per log line below `:error`, about 900
reductions (10-20 µs) per failure in the failing process, about 7 KB per
process that logs (at most ~36 KB: 100 crumbs of 200 bytes), one database
connection.

## What it cannot see

Unsupervised processes that `exit` or are killed; exceptions you rescue
without `capture_exception`; NIF crashes and OOM kills of the VM; `halt`;
a burst of plain `spawn` crashes, which the VM itself drops before any
handler (the page shows what was lost). `Blackbox.stats/0` and the foot of the
inbox count everything captured, deduped, expected and dropped.

## Design

The decision record and the research behind it are in `docs/`:
`docs/adr/0001-every-failure-and-what-came-before.md`, the research in
`docs/research/0001-errors/` (eight reports, five TDD labs with 256 tests, a
review), and the build log in `docs/plans/0001-v1-build.md`.

## Contributing

`mix ci` runs what CI runs: the format check, the compile with warnings as
errors, the compile without the optional deps, the check that `lib` names no
host, and the tests (they need a local Postgres). `bin/ci` runs it on both
toolchains CI tests, Elixir 1.18 / OTP 27 and 1.20 / OTP 28, through asdf.
