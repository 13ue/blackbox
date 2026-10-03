# Changelog

## 0.1.0 (unreleased)

The first version, used by 1charta as a git dependency before any hex
release.

- Capture: a primary `:logger` filter for raw OTP reports, a `:logger`
  handler, telemetry for Phoenix, Plug, Bandit and `telemetry` itself, and a
  watchdog that re-installs them.
- One failure, one occurrence: dedupe by source in the failing process; a
  supervisor's report merged into the child's own.
- Fingerprint v1: kind, type and the top 3 in-app frames.
- What came before: a crumb ring per process (logs, telemetry, Ecto, Finch,
  `Blackbox.crumb/2`), reset per request; the caller's crumbs and context
  through `$callers` and `client_info`; last message, state and `:sys` log;
  a system snapshot.
- Scrubbing of terms and text before anything is stored.
- The Postgres store: own pool, upsert, retention, flush on stop, the spool,
  `Blackbox.Migration` and `mix blackbox.gen.migration`.
- `Blackbox.Plug`: the inbox, the issue timeline, versioned JSON, Markdown
  for agents; resolve, mute, reopen, note.
- `capture_exception/3`, `capture_message/2`, `capture_browser/2`,
  `current_ref/0`, `set_context/1`, `pause/0`, `resume/0`, `stats/0`.
