# Blackbox

A flight recorder for the BEAM. It catches every failure it can see (process
crashes, supervisor reports, Phoenix and Bandit exceptions, `Logger.error`),
keeps what happened before each one (a per-process breadcrumb ring, the
GenServer's last message and state, the caller's stack), stores it in the
app's own Postgres, and shows one timeline per failure to people and agents.

In progress: capture, the Postgres store and scrubbing are built (plan 0001, M1-M3); the page and the API are next. The decision record and the research that led to it are in
`docs/`: `docs/adr/0001-every-failure-and-what-came-before.md` and
`docs/research/0001-errors/` (eight reports, five TDD labs with 256 tests, a
heavy-scrutiny review, and the research page `index.html`).

Requires OTP 27+ and Elixir 1.18+.
