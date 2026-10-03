# 03 The field beyond Elixir: "what happened before", UX, grouping, noise, agents

Agent 03, 2026-09-27. Scope: BRIEF item 03. Status: done. Sources are read, not run. There is no lab for this item.

## Summary for the lead

1. Noise is the top complaint about error trackers and the reason people switch them off (HN, 8 of 47 on-topic comments). The fix is issue state: new, regressed after a resolve-in-release, escalating against the issue's own baseline, muted-until. Notify on those three and nothing else.
2. Grouping, the Sentry way: fingerprint, then in-app stack frames (module, file, context line; never line numbers), then exception type+value, then the message *template*. For the BEAM: exception module or exit-reason shape + in-app `{m,f,arity}`, with a `grouping_version`. "In-app" is exact on the BEAM via `:application.get_application/1`.
3. Every tool keeps "before" as a bounded ring shipped only with an error: Rollbar 100 events, Honeybadger 40, Sentry replay "the last 60 seconds ... (approximately 2-5MB)", Go FlightRecorder `MaxBytes`, JFR circular buffer (<1% overhead). Copy the shape: a per-process ring by count plus a node ring by time, both byte-bounded.
4. Locals are the most loved context (HN 41754386: 17 of 44 comments). The BEAM equivalent is top-frame args plus GenServer last message and state; show them as "locals".
5. Async breadcrumbs are hard: Sentry's old SDKs got them wrong (ex-Sentry, HN 20183691). On the BEAM, `$callers` and Logger metadata can join a Task or GenServer crash to its request trail. Needs agent 06's proof.
6. Security: CERT VU#212479 "PhantomFix" (2026-09-16). A forged error posted to a public DSN steered Seer's coding agent into running attacker code. sentry-mcp marks only Seer output as untrusted, not raw event fields. Rule: event text is untrusted data in every agent response, there is no public ingest, and the tracker never auto-runs fixes.
7. The agent surface that matters is about 6 calls (search by state, issue + recommended event + breadcrumbs, resolve/mute, note), out of sentry-mcp's ~61 tools. Agents fed raw tracker output merge only ~30% of their PRs (HN 47055028), so give them state signals and dedupe first.
8. Self-hosted Sentry is too heavy (16 GB+, Kafka/ClickHouse: 29 of 150 comments in HN 43725815). The winners are GlitchTip ("10% of the effort") and Bugsink. Run inside the app with its own Postgres and no extra services.
9. UI: Sentry's page (recommended event, highlights, stack, breadcrumbs, sidebar) minus replay, suspect commits and dashboards. Add one BEAM timeline: trail + causal chain + crash + supervisor reaction + system snapshot, with relative time ("-3.2 s") first. Store wide (one record per occurrence), show narrow. Inbox, not dashboard.
10. Skip for v1: AI merge of similar issues (Sentry reports -40% new issues but runs a 161M-parameter model), rules languages, session replay, full time travel (rr/Pernosco/Replay are for dev and test, not always-on). 14 design rules are in section 9, 17 findings in section 8.

## Outline

1. Tools, one by one: what "before" data each keeps and how it shows it
2. Grouping algorithms
3. Noise and alert fatigue
4. What developers love and hate (counted, quoted, linked)
5. Time travel debugging and flight recorders
6. Wide events
7. Error tracking for AI coding agents
8. Findings table
9. Design rules for the most useful error tracker
10. Sources

## 1 Tools one by one: what "before" data each keeps, and how it shows it

All **read** (docs fetched 2026-09-27) unless marked.

| Tool | "Before" data | Bound | Shown as |
|---|---|---|---|
| Sentry | breadcrumbs (type, category, message, data, level, timestamp), auto from integrations; trace (spans across services); session replay (browser); local variables per frame (Python) | per-SDK `max_breadcrumbs` (default 100 in most SDKs; the product page does not say) | issue page shows "a few of the breadcrumbs" + "View All" drawer with search, filter by type/level, sort, timestamp format |
| Rollbar | "Telemetry": page load, clicks/inputs/navigation, xhr/fetch, console, other Rollbar items | "the last 100 events", `maxTelemetryEvents` 0..100 | "Telemetry section of an occurrence", absolute time plus time relative to `DOMContentLoaded` |
| Bugsnag | breadcrumbs by `enabledBreadcrumbTypes`, `onBreadcrumb` callback to drop/amend | `maxBreadcrumbs` (default not stated on page) | list on the event; warning: logging inside `onBreadcrumb` loops if log breadcrumbs are on |
| Honeybadger (Ruby) | ActiveSupport instrumentation: SQL (binds stripped), log lines, controller actions, any notification | "only keeps the 40 latest breadcrumb events"; metadata flat, primitives only, strings <= 64 KB | categories (custom, error, query, job, request, render, log, notice) with icons |
| PostHog | the affected user's session replay, events and properties; exceptions live in the same event store as product analytics | n/a | issue page with replay and events "in view"; "Self-driving" groups and opens PRs |
| Datadog | links to APM traces, logs, RUM; "Exception Replay" captures production variable values automatically (APM) | n/a | issue with first seen, users impacted; "Ask your local AI agent to analyze and fix errors with a single click" (JetBrains) |
| Bugsink (self-host, Sentry-SDK compatible) | whatever the Sentry SDK sends; argues locals per frame are the best breadcrumbs | n/a | Sentry-like, deliberately fewer features |

Patterns across all of them:

1. **A fixed ring of the last N events** (Rollbar 100, Sentry ~100,
   Honeybadger 40) kept in the SDK and shipped only with an error. Nobody
   ships breadcrumbs continuously. This is the flight recorder shape.
2. **Categories with icons, one line each, relative time.** Rollbar shows
   time relative to page load; that is the most useful single column
   ("3.2 s before the crash").
3. **Breadcrumb sources are the framework's own instrumentation**
   (ActiveSupport notifications for Honeybadger, DOM/network for Rollbar).
   The BEAM equivalent is `:telemetry` plus Logger: attach, do not patch.
4. **Values beat messages.** Locals per frame (Sentry Python, Bugsink blog,
   Datadog Exception Replay) are what developers praise most (HN thread
   41754386, 17 of 44 comments on it). Elixir cannot read locals of a
   crashed frame, but it has something as good: the function **arguments**
   of the top frame (`{m, f, args}` in the stacktrace for
   FunctionClauseError/badarg) and the GenServer's **last message and
   state** in the crash report. Show those as the "locals".
5. **Callbacks to scrub or drop** (`onBreadcrumb`, `telemetryScrubber`,
   `scrubTelemetryInputs`, password inputs by default). Scrubbing must be
   default-on for known secret keys.

### Honeycomb and wide events (read, charity.wtf 2024-12-20)

Observability 2.0 = "wide, structured log events, single source of truth",
arbitrary high cardinality, one event per request per service, instead of
three pillars. The relevance for an error tracker: an error is best stored
as **one wide event** (every field of request, process, job, release,
system, user flattened into it) so that the "which releases / which users /
which node" questions are a `GROUP BY`, not a feature. Bugsink's
"Track errors first" pushes the other way on scope: "One exception is worth
a thousand logs"; error trackers that drift into full APM platforms lose
the core value. Both are right: store wide, show narrow.

## 2 Grouping algorithms

### Sentry (read, docs 2026-09-27)

- Order: "All versions consider the `fingerprint` first, the `stack
  trace` next, then the `exception`, and then finally the `message`."
- Stack trace: only in-app frames: "Sentry only groups by stack trace
  frames that the SDK reports and associates with your application". Per
  frame: module, normalized filename (revision hashes removed), normalized
  context line. **Line numbers are not part of it** (so a shift from
  editing above does not split the issue), but the source *line text* is,
  when source context is available.
- Fallbacks: exception `type` + `value`; then "the message without any
  parameters" (i.e. the log template, not the formatted string).
- Grouping config is versioned; a new version "is only applied to new
  events going forward".
- User controls, easiest first: merge issues; fingerprint rules
  (`error.type`, `error.value`, `message`, `logger`, `level`,
  `stack.function`, `stack.module`, `tags.*`, `app` -> fingerprint with
  `{{ default }}`, `{{ transaction }}` and a `title=` override, e.g.
  `logger:my.package.* level:error -> error-logger, {{ logger }} title='Error from Logger {{ logger }}'`);
  stack trace rules (`+app`/`-app`, `+group`/`-group`, `^-group`/`v-group`,
  `max-frames`, e.g. `stack.abs_path:**/node_modules/** -group`); SDK
  fingerprint.
- AI merge on top: new hash -> embedding (fine-tuned transformer, 161M
  params, 768 dims) of message + in-app frames -> pgvector HNSW (M=16,
  hash-partitioned by project) -> top-100 rerank -> merge into the existing
  issue if within a "very conservative threshold". Result: "new issue
  creation drops by roughly 40%", false merges "virtually zero".

### Datadog, PostHog, Rollbar, Bugsnag (read)

Datadog groups "thousands of similar errors into a single issue" (type,
message, frames; details not on the fetched page). PostHog has issue
grouping rules and auto-groups. Rollbar and Bugsnag also group server-side
by exception class + in-app frames (well known; not re-fetched, so treat as
read-from-memory, low confidence).

### What this means for the BEAM

- Elixir stacktraces carry `{module, function, arity, [file:, line:]}`.
  Fingerprint on **exception module + in-app `{m, f, arity}` frames**, no
  line numbers, no message values: that is Sentry's rule translated, and it
  survives line shifts by construction (agent 08 proves it).
- **"In-app" is decidable exactly on the BEAM**: a module belongs to the
  app if `:application.get_application(mod)` is one of the host's OTP apps
  (not `:elixir`, `:stdlib`, `:phoenix`, `:ecto`...). Sentry needs path
  heuristics and rules for this; we get it free.
- The message fallback must use the **template**: for `Logger.error`
  events, the `:report`/format string before interpolation (`:logger`
  keeps `{format, args}` separately in `msg`), and for exceptions a
  normalized message with numbers, pids, refs, hex ids and quoted strings
  replaced (`#PID<0.123.0>` -> `#PID<>`). Without this, every
  `** (exit) {:timeout, {GenServer, :call, [#PID<...>, ...]}}` is its own issue.
- Exits need their own normalizer: `{:timeout, {GenServer, :call, _}}`,
  `:noproc`, `{:shutdown, _}`, `:killed` are reasons, not exceptions;
  group by the reason's shape (atom or tuple head) plus the call site.
- Keep a **grouping version** column from day one so the rule can change
  without silently splitting old issues.
- Offer exactly two escape hatches: a per-call-site `fingerprint:` option
  (like SDK fingerprinting) and "merge these issues" in the UI. Rules
  languages are power-user features for 10k-issue orgs; YAGNI.

## 3 Noise and alert fatigue

### How Sentry fights noise (read, docs 2026-09-27)

- **Issue states**: New ("created in the last 7 days"), Ongoing, Escalating
  ("exceeded its forecasted event volume"), Regressed ("A resolved issue
  that's come up again"), Archived, Resolved. Each is a search filter
  (`is:new`, `is:regressed`, ...).
- **Archive until escalating** is the default archive. "Archived forever"
  still records events but never escalates.
- **Resolve in next release / current release / a given release**: a
  regression is only a regression if it happens in a release after the fix.
- **Escalation forecast**: for issues 7+ days old, the max of a "spike
  limit" (hourly average weighted by day-of-week plus variance over the
  previous week) and a "bursty limit" (max hourly volume and coefficient
  of variation, for cron-like issues); for younger issues "the maximum
  hourly volume ... multiplied by 10". Does "not work for merged/unmerged
  issues".
- **"Delete and Discard Forever"**: drops future events at ingest.
- **AI merge** of near-duplicate issues: -40% new issues (section 2).

### What users say (HN comments, hand-coded; section 4 has method)

From the comment searches "sentry noise", "sentry grouping", "sentry
breadcrumbs" (120 comments fetched, 47 on topic):

| Theme | count | examples (HN item id) |
|---|---|---|
| noise makes the tracker useless or ignored | 8 | "We've had scenarios ... go undetected because of the noise Sentry generates" (31781473); "I ended up kind of letting the Sentry reports fade into the background, and eventually I turned it off entirely" (46757478); "a web UI displaying a lot of noise disguised as data" (45845661); "detecting which errors are important and which are noise ... (the biggest problem with Sentry in my experience)" (38877607); agents turning noise into PRs (47056593, 47132661) |
| grouping is the reason to use a tracker | 5 | "mostly for the top notch exception grouping" next to Datadog (22917534); "good at sorting out the noise from the signal" (34394266) |
| grouping controls are painful / too rigid | 3 | "Sentry's grouping interface that was a major PITA ... weird regex-ish matching" (37394343); left Sentry for custom grouping rules (5713008); GlitchTip's grouping/filtering "very basic" (40226911) |
| breadcrumbs solved it | 5 | "about 10 minutes of browsing the breadcrumbs for a few users to see the pattern" (16363537); "I'm especially fond of the breadcrumbs" (13430509); "feed your logs into sentry. It can use low-sev logs as breadcrumbs and the high-sev logs as events" (22575061) |
| breadcrumbs not enough / wrong | 4 | "they don't provide enough context" (16170929); "many bugs are not easily understood by looking at the breadcrumbs trail" (11902161); "a mountain of breadcrumbs" from a library (20359862); ex-Sentry: old SDKs had "incorrect breadcrumb collection in async code" (the_mitsuhiko, 20183691) |
| wants a simple inbox, not a dashboard | 4 | "overwhelming dashboards ... so i made mine look like gmail" (46738405, 46300759); "I wrote a logging handler that stores the log records (including traceback) in a database table" for GDPR (43727767) |

Two lessons that matter for the BEAM:

1. **Noise is the top complaint about the category**, above price (for
   hosted) and weight (for self-hosted). The fixes that work are all about
   *state*: new vs seen, regressed-after-fix, escalating vs baseline,
   muted-until. A tracker that only lists errors by count fails.
2. **Breadcrumbs in async code are hard**; Sentry got them wrong for years
   (20183691). On the BEAM the context problem is sharper (every Task is a
   new process with an empty process dictionary), but the answer is also
   better: `$callers` and Logger metadata propagation let a crash in a
   Task find the request's trail. Agent 06 measures it.

### Noise sources specific to a BEAM app (from the above plus BEAM knowledge)

- One failure, many reports: a GenServer crash gives a crash report, a
  supervisor child_terminated report, the linked caller's exit, often a
  `Logger.error` from the caller, and a Phoenix telemetry exception if a
  request waited on it. Must be **one occurrence with the others as its
  trail**, not five issues (agents 04/05 measure the shapes).
- Restart loops: a child crashing 3 times in 5 s then the supervisor giving
  up is one story. Group by fingerprint and show the count and the
  supervisor's final decision.
- Expected failures: 404 (`Phoenix.Router.NoRouteError`,
  `plug_status` < 500), client disconnects, `{:shutdown, _}` exits,
  `Ecto.NoResultsError` rendered as 404. Default filter: drop exceptions
  whose `Plug.Exception.status/1` is < 500 and normal/shutdown exits;
  count them but do not make issues.
- Bursts: 10k identical errors/s must become one issue with a counter, and
  the trail stored for the first K and a sample after (Sentry `Dedupe` +
  sampling, agent 01).

## 4 What developers love and hate (first pass: Hacker News)

Method: HN Algolia API (no search budget), 8 threads, 354 comments,
flattened and regex-coded per theme, then hand-read. Counts are "comments
matching the theme regex", so treat them as rough. Raw data: scratchpad
`r03/hn_*.json`; counts in `logs/03-web.log`.

| Thread (HN id, comments) | top themes (comments matching) |
|---|---|
| "I gave up on self-hosted Sentry" (43725815, 150) | self-host weight 29, price 19, simpler alternatives named 15, love 12 |
| "Track Errors First" (44190643, 52) | simpler alternatives 11, love 9, locals/context 6 |
| "Local Variables as Accidental Breadcrumbs" (41754386, 44) | locals/context 17 |
| "Launch HN: Sonarly, AI agent to triage alerts" (47049776, 17) | noise 6, grouping 4 |
| "Show HN: Superlog, observability that fixes bugs" (48195021, 48) | love 12, price 5 |

Quotes (read, linked by HN item id `news.ycombinator.com/item?id=N`):

- Weight of self-hosted Sentry: "Each release would unleash more containers
  and consume more memory until we couldn't run anything on the 32gb server
  except Sentry." (crimsonnoodle58, 43726116). "It also doesn't make sense to
  spin up a 16GB machine (minimum!) to track the errors on those 4-8GB VPS
  which are running my production services." (mplantsheer, 43726295).
  GlitchTip "does 99% of what Sentry did with 10% of the effort"
  (mstaoru, 43728899). Counterpoint: 96 cores/512 GB on Hetzner for
  ~$300/month at 25M transactions (Weryj, 43726107); Armin Ronacher,
  ex-Sentry: "There is no secret incentive to make Sentry hard to operate"
  (43726552).
- Feature creep for small teams: "Sentry is just too much for a single
  developer" (lawgimenez, 44191400); "over time Sentry's interface has
  gotten considerably worse" (drcongo, 44192896); "a bit over-the-top
  complicated as of late" (jensenbox, 44191294).
- Errors beat logs: "I have rarely found logs useful to debug or track down
  any production issue. Errors on the other hand are almost always useful."
  (arp242, 44191481). What Sentry does that Datadog does not: "the way
  Sentry aggregates errors over time" (jensenbox, 44204333).
- Privacy: "most companies are always sending some PII (or even PHI....) to
  Sentry because filtering is always one step behind. Having it self-hosted
  would be my strong preference" (jtwaleson, 44191166).
- Locals are the most-loved context: "I bloody hate Python stacktraces
  because they usually don't have enough information to fix the bug"
  (41801474); "The stacktraces are great when logged through Sentry so even
  on production I can normally spot the bug immediately" (41801586). Zope's
  `__traceback_info__`: a local that is only printed if a traceback is
  shown (41801604), i.e. breadcrumbs that cost nothing until a crash.
- Agents on top of a tracker, as practiced: "a github action that runs
  hourly. It pulls new issues from sentry, grabs as much json as it can from
  the API, and pipes it into claude. Claude is instructed to either make a
  PR, an issue, or add more logging data if it's insufficient to diagnose.
  I would say 30% of the PRs i can merge [...] the volume of sentry alerts
  is high, and the issues being fixed are often unimportant, so it tends to
  create a lot of busy work" (nojs, 47055028). Sonarly's answer: "we group
  alerts by RCA (so no duplicate PRs) and filter by severity [...] turning
  every alert into a PR just moves the problem from Sentry to GitHub"
  (47055501).

Reddit and ElixirForum: not counted. `reddit.com/search.json` answered 403
to curl, and `elixirforum.com/search.json` now redirects to an HTML page
(the forum no longer serves Discourse JSON). Agent 02 owns the Elixir
field; I did not spend web searches on it.

## 5 Time travel debugging and flight recorders

| System | What it keeps | Bound | Trigger | Overhead (as published) |
|---|---|---|---|---|
| Go 1.25 `runtime/trace.FlightRecorder` | full execution trace: goroutine scheduling, syscalls, GC, user regions | `MinAge` (suggested ~2x the window you want) and `MaxBytes` (example 1 MiB) | program calls `WriteTo()` when it sees a problem, e.g. a slow request | "greatly reduced" since 1.21; no % given |
| JDK Flight Recorder | JVM + app events (GC, locks, I/O, custom events) | thread-local buffers -> global circular buffer, "only the last few minutes" without disk | dump on demand or on exit | "less than one percent" with default settings |
| Sentry session replay, buffer mode | DOM + network + console of the browser tab | "the last 60 seconds ... in a memory ring buffer (approximately 2-5MB)" | an error sampled by `replaysOnErrorSampleRate`: "the buffered 60 seconds *before* the error plus everything *after* is uploaded" | not stated |
| rr | every nondeterministic input of a Linux process tree, replayable and reversible | whole run | record everything, debug later | "slowdowns down to <= 1.2x" on Firefox tests; single core; varies "dramatically" |
| Pernosco | rr recording turned into an "omniscient database": all states, dataflow "tracking of data values back to their sources" | whole run | offline | recording as rr |
| Replay.io | deterministic browser recording; now QA agent + MCP that lets agents "read each bug report, apply the fix, and mark the bug fixed" | per recording | test run / session | not stated |

What transfers to the BEAM:

1. **The shape that wins in production is the bounded ring plus a
   trigger** (Go, JFR, Sentry replay buffer). Full recording (rr, Pernosco,
   Replay) is a dev/test tool: too slow and too big for always-on. The BEAM
   has the cheap parts already: Logger metadata, `:telemetry`, the `:sys`
   debug log (a per-GenServer ring of the last N messages, off by default),
   and OTP 27+ trace sessions. Agent 06 measures their cost.
2. **"Before and after", not only before.** Sentry replay uploads the 60 s
   before and keeps recording after. For a server: the trail before the
   crash plus what the supervisor did after (restart, restart again,
   give up) belongs in the same timeline.
3. **Time-window, not only count.** Go and JFR bound by age and bytes;
   Rollbar/Honeybadger by count. A request's trail wants count (last 50
   crumbs); a system trail (memory, run queue, restarts) wants a time
   window (last 60 s). Both bounded in bytes.
4. **Dataflow is the dream feature** (Pernosco: "where did this value come
   from"). The cheap BEAM approximation: the chain of processes and messages
   that led here: `$callers`, `$ancestors`, the request id in Logger
   metadata, the Oban job id, the last message the GenServer got and from
   whom. That is a causal chain without recording every instruction.

## 6 Wide events

Covered in section 1 (Honeycomb / Charity Majors). The design consequence
in one line: store each occurrence as **one wide, flat record** (error +
request + process + job + release + node + system health + user) so that
any breakdown ("only on node b", "only since release 42", "only for
Space X") is a query, and keep the UI narrow (the issue, its trail, its
counts). Sentry's "tags" and "event highlights" are the narrow view over
the wide record; that is the right split.

## The issue page: what the best UI shows (synthesis)

Sentry's issue page order (read, docs 2026-09-27): header (message, counts,
users affected, actions) -> event navigation with a **"Recommended" event**
("the event with the most context": recent within 7 days, matches the
search, has replay/profile/trace) -> **event highlights** (admin-chosen
tags promoted to the top) -> stack trace -> suspect commits -> breadcrumbs
-> trace preview and related issues -> replay -> tags, contexts, request ->
sidebar: first/last seen and release, activity, similar and merged issues,
Seer.

Screenshots: Sentry's public sandbox (`sandbox.sentry.io`) now gates the
UI behind a "enter your email" form; per the brief I did not create a
login, so there are no `shots/03-*` files. The layout above is from the
docs.

What I would keep, drop and add for a single-developer, self-hosted,
agent-heavy BEAM tool:

- Keep: header with state (new / regressed / escalating / muted),
  count sparkline, first and last seen **with release**; one recommended
  occurrence; stack trace with in-app frames expanded and deps collapsed;
  the trail; the request/job/message; similar issues.
- Drop: suspect commits (needs a Git host integration), session replay,
  participants, performance/insights tabs, dashboards (the "Track errors
  first" and HN "too much for a single developer" complaints).
- Add (BEAM-native): **one timeline** that merges, by timestamp, the
  process's own trail (Logger lines below the handler level, telemetry
  spans, messages received), the causal chain (request -> Task ->
  GenServer, via `$callers`), the crash, and what the supervisor did after
  (restart N, gave up); **the "locals"**: arguments of the top frame, the
  GenServer's last message and state (scrubbed, truncated); **system at
  that moment**: memory, run queue, process count, the process's mailbox
  length and reductions; **exit reason** shown as a first-class field,
  not a stringified tuple.
- Relative time as the first column ("-3.2 s") like Rollbar's
  "relative to DOMContentLoaded", absolute on hover.

## 7 Error tracking for AI coding agents

### Sentry MCP (read, getsentry/sentry-mcp @ 7486ab1, 2026-09-25)

A remote MCP server (mcp.sentry.dev) plus stdio package. The catalog in
`packages/mcp-core/src/tools/catalog/` has 63 files, about 61 tools. The
ones that matter for us: `search_issues` (natural language or Sentry query
syntax: `is:unresolved`, `is:regressed`, `firstSeen:-24h`,
`release:latest`), `get_issue_details`, `get_event_stacktrace`,
`get_issue_breadcrumbs` ("See the user and application actions leading up
to an error ... Reconstruct the immediate context before an issue
occurred"), `get_trace_details`, `search_issue_events`, `update_issue`
(resolve, ignore, `ignoreMode='untilOccurrenceCount', ignoreCount=100,
ignoreWindowMinutes=60`), `add_issue_note`, `analyze_issue_with_seer`.
The descriptions are written for the model: "USE THIS TOOL WHEN USERS ...
DO NOT USE for ... TRIGGER PATTERNS" (`get-issue-details.ts`). The output
is Markdown, not JSON (`internal/formatting.ts`, `formatEventOutput` at
line 227).

Lesson: the useful agent surface is small. Search, one issue with its
latest event and the trail before it, change status, leave a note. The
other ~50 tools are Sentry's admin surface (alerts, DSNs, teams, monitors).

### Prompt injection through error payloads (read)

`sentry-mcp` wraps only Seer's LLM output in `<seer_analysis>` provenance
tags "Seer content is LLM-generated, so it must be marked as untrusted
data" (`tool-helpers/seer.ts:118-130`); raw event fields are passed as
Markdown without a boundary. That gap is real: **PhantomFix**, CERT
VU#212479 (CVE-2026-90999, disclosed 2026-09-16): an attacker posts a fake
error to a project's public DSN; Seer "generates a root-cause analysis that
uses attacker-controlled event fields, including exception messages, stack
traces, source context, and breadcrumbs"; the coding agent it hands off to
"downloads and executes a package controlled by the attacker ... prior to
any human review of a pull request". Mitigations listed: disable automated
remediation, restrict package installs in the agent, "defensive filtering
of telemetry before analysis".

For blackbox this is a design input, not a footnote: an error message is
user-controlled text (a param echoed in `ArgumentError`, a filename, an
HTTP body in a breadcrumb). Whatever the agent API returns must mark event
fields as data, and there must be no public ingest endpoint by default
(in-process capture has no DSN to forge, which is a real advantage over
the Sentry model).

### Agents on top of trackers, in practice (read)

- A user's hourly GitHub Action pipes new Sentry issues into Claude:
  30% of the PRs mergeable, the rest band-aids; the issue volume creates
  "busy work" (HN 47055028, quoted in section 4).
- Sonarly (YC W26) groups alerts "by RCA (so no duplicate PRs) and filter
  by severity" before an agent sees them (HN 47055501).
- Sentry's Seer agent: natural-language debugging of production issues
  (thenewstack, 2026-04-29, HN 47951528; not fetched).

Consequence: an agent needs the same things a human needs, but even more
the "is this new, is it important, is it already being handled" signals,
or it burns tokens and review time on noise.

## 8 Findings table

| id | what | evidence | priority | proposal (one line) | size |
|---|---|---|---|---|---|
| 03-F1 | Noise is the #1 complaint about error trackers; it gets them turned off | HN 46757478, 31781473, 38877607; 8 of 47 on-topic comments | P0 | Issue state machine from day one: new, ongoing, regressed (after a resolve-in-release), escalating, muted-until | M |
| 03-F2 | Grouping ignores line numbers and uses in-app frames only | Sentry grouping docs | P0 | Fingerprint = exception module (or normalized exit reason) + in-app `{m,f,arity}` frames; no lines, no values; `grouping_version` column | S |
| 03-F3 | "In-app" needs heuristics elsewhere, is exact on the BEAM | `:application.get_application/1` | P1 | Mark a frame in-app iff its module's OTP app is one of the host's apps | S |
| 03-F4 | Message fallback must use the template, not the formatted text | Sentry: "the message without any parameters" | P0 | Group `Logger.error` by format/report template; normalize pids, refs, numbers, hex in exception messages | S |
| 03-F5 | Every tool keeps a bounded ring of recent events and ships it only with an error | Rollbar 100, Honeybadger 40, Sentry replay 60 s / 2-5 MB, Go MaxBytes, JFR circular buffer | P0 | Per-process ring by count plus a node-wide ring by time, both byte-bounded, flushed only on a crash | M |
| 03-F6 | Locals are the most praised context | HN 41754386 (17/44 comments), Datadog Exception Replay, Bugsink | P1 | Show top-frame args and GenServer last message/state as "locals", scrubbed and size-capped | S |
| 03-F7 | Async breadcrumbs went wrong in Sentry for years | the_mitsuhiko, HN 20183691 | P1 | Follow `$callers`/`$ancestors` and Logger metadata to join a Task/GenServer crash to its request trail; test it | M |
| 03-F8 | Error payloads are an injection vector for AI agents | CERT VU#212479 PhantomFix (2026-09-16); sentry-mcp wraps only Seer output | P0 | Agent API marks every event field as untrusted data; no public ingest endpoint; agents never auto-run fixes | S |
| 03-F9 | The useful agent surface is ~6 calls, not 61 | sentry-mcp catalog (63 files) vs what agents use | P1 | JSON/Markdown API: list issues (state filter), get issue + recommended occurrence + trail, occurrences, resolve/mute, note | S |
| 03-F10 | Agents on raw tracker output make band-aid PRs (30% mergeable) and busy work | HN 47055028, 47055501 | P1 | Give agents the state signals (new/regressed/escalating, count, first release) and dedupe by root cause before they act | S |
| 03-F11 | Self-hosted Sentry is too heavy (16 GB+, Kafka, ClickHouse); simple alternatives win on setup | HN 43725815 (29 comments on weight), GlitchTip "10% of the effort", Bugsink | P0 | Run inside the app, store in the app's Postgres, zero extra services | M |
| 03-F12 | Small users want an inbox, not a dashboard | HN 44191400, 46738405, 43727767; "Track errors first" | P1 | One list, one issue page, one timeline; no dashboards | S |
| 03-F13 | Store wide, show narrow | Honeycomb; Sentry tags vs highlights | P2 | Occurrence = one wide JSONB record; UI shows a fixed short header and the trail | S |
| 03-F14 | "Before" plus "after" | Sentry replay buffer uploads before and after | P2 | Append the supervisor's reaction (restarts, give-up) to the occurrence timeline | S |
| 03-F15 | Escalation needs a baseline, not a fixed threshold | Sentry escalating algorithm (weekly spike/bursty limits, 10x for young issues) | P2 | v1: escalating = hourly count > 10x the issue's max hourly count of the last 7 days; refine later | S |
| 03-F16 | Expected failures drown real ones | 404s, client disconnects, shutdown exits | P0 | Default filter: Plug status < 500 and normal/shutdown exits are counted, not made into issues | S |
| 03-F17 | Privacy: filtering "always one step behind" | HN 44191166 | P1 | Scrub by key name at capture (password, token, secret, authorization, cookie, key), before the ring buffer | S |

## 9 Design rules for the most useful error tracker

1. **Catch everything, report once.** One failure that is seen by the
   logger handler, the supervisor, the caller and telemetry becomes one
   occurrence; the other sightings are lines in its timeline.
2. **An issue is a state, not a row count.** New, ongoing, regressed
   (only after a resolve tied to a release), escalating (against the issue's
   own baseline), muted until a date/count/escalation, resolved. Notify on
   new, regressed and escalating only. Never on "happened again".
3. **Group by where, not by what.** Fingerprint = kind + normalized
   exception module or exit-reason shape + in-app `{m, f, arity}` frames.
   No line numbers, no ids, no values. Version the rule.
4. **Keep the last N and the last T, ship them only on a crash.**
   Per-process ring (count), node ring (time), both byte-bounded; zero
   work on the happy path beyond appending to the ring.
5. **Follow the causal chain.** The trail of a crash in a Task or
   GenServer includes the request, job or message that caused it
   (`$callers`, Logger metadata, message sender).
6. **Show values, not just frames.** Top-frame arguments, GenServer last
   message and state, the exit reason as a structure; truncated and
   scrubbed.
7. **One timeline, relative time.** Merge trail, chain, crash, supervisor
   reaction and system snapshot into one list with "-3.2 s" in the first
   column.
8. **Expected is not an error.** 4xx exceptions, disconnects, normal and
   shutdown exits are counted, never issues, unless the user says so.
9. **The tracker never hurts the app.** Bounded buffers, drop-and-count
   under floods, a crash in the tracker is caught and counted, no
   recursion, no network in the caller's process.
10. **Run where the app runs.** No extra services: the app's Postgres,
    a plain HTML page served by a Plug, no LiveView or Hologram needed.
11. **Scrub at capture.** Secrets never enter the ring buffer, so they
    can never reach storage, the UI or an agent.
12. **Agents get a small, honest API.** List issues by state, get one issue
    with its recommended occurrence and timeline, resolve/mute/note. Every
    event field is labelled untrusted data; the tracker never triggers an
    agent to run code on its own.
13. **Store wide, show narrow.** Keep every field in the occurrence for
    queries; show a short header, the trail and the counts.
14. **Inbox, not dashboard.** One list sorted by state and recency, one
    issue page. If a feature needs a chart, it is probably APM, and APM is
    somebody else's job.

## Recommendations for the lib

1. Occurrence schema: `issue_id, kind (:error | :exit | :throw | :log),
   exception_module | exit_reason_shape, message_template, message,
   stacktrace (in-app flag per frame), fingerprint, grouping_version,
   release, node, pid, process_label, mfa, caller_chain, request | job |
   message (scrubbed), locals (top-frame args, last message, state),
   trail (list of crumbs), system (memory, run_queue, process_count,
   mailbox_len), inserted_at`. One JSONB column for the wide rest.
2. Issue schema: `fingerprint (unique), title, state, first_seen,
   first_release, last_seen, last_release, count, muted_until,
   muted_until_count, resolved_in_release, regressed_at, hourly_counts
   (small ring for escalation)`.
3. State rules in one pure module with table tests: resolve + new
   occurrence in a later release -> regressed; muted + count > baseline x 10
   -> escalating; resolve without release -> regress on any new occurrence.
4. Fingerprint in one pure function with property tests: same fingerprint
   after inserting lines above; different after a different in-app
   function; same across pids/refs/ids in the message.
5. Default ignore list: exceptions with `Plug.Exception.status/1 < 500`,
   exits `:normal`, `:shutdown`, `{:shutdown, _}`; counted in a per-kind
   counter visible on the list page.
6. Agent surface: `GET /blackbox/api/issues?state=`, `GET
   /blackbox/api/issues/:id` (issue + recommended occurrence + timeline as
   Markdown or JSON), `POST .../resolve|mute|note`; the same as a tiny MCP
   server later. Wrap event text in explicit `<event_data untrusted>`
   boundaries in the Markdown form.
7. The UI is a Plug that renders server-side HTML (no JS framework
   required), mountable in any router; 1charta mounts it behind its admin.
8. Notifications (v1): a callback `on_issue(:new | :regressed |
   :escalating, issue)`; the host decides (email, Slack, a 1charta board
   sticky). No built-in integrations.
9. Skip for v1: AI merge of similar issues, rules languages, session
   replay, suspect commits, dashboards, performance monitoring.

## 10 Sources

All fetched 2026-09-27 (read unless noted). Commands and counts in
`logs/03-web.log`. WebSearch calls used: 0 (HN Algolia API, WebFetch and
one git clone instead).

- Sentry grouping: https://docs.sentry.io/concepts/data-management/event-grouping/ ,
  .../fingerprint-rules/ , .../stack-trace-rules/
- Sentry AI grouping: https://blog.sentry.io/how-sentry-decreased-issue-noise-with-ai/
- Sentry breadcrumbs: https://docs.sentry.io/product/issues/issue-details/breadcrumbs/
- Sentry issue page: https://docs.sentry.io/product/issues/issue-details/
- Sentry states: https://docs.sentry.io/product/issues/states-triage/ ,
  .../escalating-issues/
- Sentry replay buffer: https://docs.sentry.io/platforms/javascript/session-replay/understanding-sessions/
- Sentry Seer: https://docs.sentry.io/product/ai-in-sentry/seer/
- Sentry MCP: github.com/getsentry/sentry-mcp @ 7486ab1 (2026-09-25),
  `packages/mcp-core/src/tools/catalog/*.ts`,
  `packages/mcp-core/src/internal/tool-helpers/seer.ts:118-130`,
  `packages/mcp-core/src/internal/formatting.ts:227,1958`
- PhantomFix: https://kb.cert.org/vuls/id/212479 (CVE-2026-90999)
- Rollbar telemetry: https://docs.rollbar.com/docs/rollbarjs-telemetry
- Bugsnag breadcrumbs: https://docs.bugsnag.com/platforms/javascript/customizing-breadcrumbs/
- Honeybadger breadcrumbs: https://docs.honeybadger.io/lib/ruby/getting-started/breadcrumbs/
- PostHog: https://posthog.com/docs/error-tracking
- Datadog: https://docs.datadoghq.com/error_tracking/
- Bugsink: https://www.bugsink.com/ ,
  https://www.bugsink.com/blog/track-errors-first/ ,
  https://www.bugsink.com/blog/local-variables-as-accidental-breadcrumbs/
- Wide events: https://charity.wtf/2024/12/20/on-versioning-observabilities-1-0-2-0-3-0-10-0/
- Go flight recorder: https://go.dev/blog/flight-recorder
- JFR: https://docs.oracle.com/javacomponents/jmc-5-4/jfr-runtime-guide/about.htm ,
  https://docs.oracle.com/en/java/javase/21/jfapi/why-use-jfr-api.html
- rr: https://rr-project.org/ ; Pernosco: https://pernos.co/about/overview/ ;
  Replay.io: https://docs.replay.io/
- HN threads (hn.algolia.com/api/v1/items/N): 43725815, 44190643,
  41754386, 47049776, 48195021, 36008564, 43681141; comment searches
  "sentry noise", "sentry grouping", "sentry breadcrumbs"; individual
  comments cited by id as `news.ycombinator.com/item?id=N`.
- Not reachable: reddit.com JSON (403), elixirforum.com search JSON
  (redirects to HTML); sandbox.sentry.io (email gate, not entered).
- Not verified here, from memory, low confidence: Rollbar/Bugsnag
  server-side grouping details; Sentry SDK default `max_breadcrumbs` 100.
