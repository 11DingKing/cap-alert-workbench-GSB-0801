# CAP Alert Workbench

A Common Alerting Protocol (CAP 1.2) authoring, review, and publishing workbench
built with Elixir/OTP, Phoenix, Phoenix LiveView, Ecto and PostgreSQL.

Duty officers draft rainstorm / severe-convection advisories as structured public
alerts. A draft must pass review before it can be published. Once published the
content is immutable; any later change must be issued as a **correction**
(`msgType=Update`) or a **cancellation** (`msgType=Cancel`).

## Initial message

The seed creates alert `CN-20260729-GD-RAIN-001` with:

| Field | Value |
| --- | --- |
| sent | `2026-07-29T08:00:00Z` |
| status | `Actual` |
| msgType | `Alert` |
| scope | `Public` |
| language | `zh-CN` |
| urgency | `Immediate` |
| severity | `Severe` |
| certainty | `Likely` |
| area codes | `440800` (湛江市), `440900` (茂名市) |

## Architecture

The code is split into a strict domain/service layer and a thin web layer.

* `lib/cap_alert_workbench/cap/` — domain:
  * `Enums` — explicit atoms for every CAP value and workflow state, with
    canonical-string mappers. No free-form string concatenation for states.
  * `Message` — immutable CAP message value object with validation.
  * `AreaCodes` — stable registry of administrative area codes.
  * `VersionStateMachine` — explicit pattern-matched lifecycle transitions.
  * `Alert`, `Version`, `Review`, `AuditEvent`, `OutboxMessage` — Ecto schemas.
  * `Xml.Codec` + `Xml.SaxTreeBuilder` — secure CAP XML serialization and
    SAX-based parsing. DOCTYPE / entity / notation declarations are rejected
    before they can resolve, so external entities are never fetched. Text and
    attributes are escaped by `XmlBuilder`, never by string concatenation.
    Unknown extension elements round-trip.
  * `Cap` — the public use-case boundary. LiveViews and API controllers call
    this module only; they never touch status fields directly. All mutations
    run in `Ecto.Multi` transactions that atomically update state, insert
    immutable versions, append audit events, and enqueue notification
    outbox messages.
  * `OutboxDispatcher` — polls the transactional outbox and fans
    notifications out via PubSub.
* `lib/cap_alert_workbench_web/live/alert_live/` — LiveView UI (list + editor
  with tabs for draft, version/diff, review, publish, correction/cancellation
  and audit).

### Version lifecycle

```
draft ──submit──▶ in_review
in_review ──approve──▶ approved
in_review ──request_changes / reject──▶ rejected
approved / rejected ──revise/edit──▶ draft
approved ──publish──▶ published
published ──correct──▶ published  (old version → superseded, new correction version)
published ──cancel──▶ canceled      (old version → superseded, new cancellation version)
```

Reviews are bound to a specific content revision. Editing a draft while it is
under review bumps the revision and marks the prior review stale; the old
decision cannot publish new content.

### Concurrency

* Optimistic locking on `draft_lock_version`, verified **after** acquiring the
  `SELECT ... FOR UPDATE` row lock so two browsers editing the same draft
  serialize and exactly one wins.
* Every successful edit also bumps `draft_revision`, invalidating in-flight
  reviews.
* Publishing uses `FOR UPDATE`, checks current status and approved-version
  revision, and sets `published_at`. A partial transaction failure rolls back
  state, versions, audits and outbox together; duplicate publishes receive a
  conflict.

## Requirements

* Erlang/OTP 29, Elixir 1.20
* PostgreSQL (configurable in `config/dev.exs` / `config/test.exs`)

## Setup

```bash
mix deps.get
mix ecto.setup        # create, migrate, seed the initial alert
mix assets.setup      # install tailwind + esbuild
mix assets.build      # build CSS/JS once (or let the dev watcher do it)
```

## Run

```bash
mix phx.server
# open http://localhost:4000
```

The initial alert is visible on the list page. Open it in two browser tabs,
edit in both, and save to see optimistic-lock conflicts; edit while a review
is pending to see stale-review rejection; publish twice to see idempotent
duplicate rejection.

## Format, test, build

```bash
mix format            # Mix native formatter
mix test              # creates/migrates the test DB and runs all tests
mix assets.build      # builds the CSS/JS bundles
mix precommit         # compile --warnings-as-errors + format + test
```

The test suite covers the state machine, CAP XML round-trips (including special
characters, namespaces, unknown extensions and XXE rejection), optimistic
locking, stale reviews, duplicate publishing and API behaviour.

## REST API

All endpoints are under `/api`:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/alerts` | list alerts |
| `POST` | `/api/alerts` | create a draft |
| `GET` | `/api/alerts/:id` | show alert with versions |
| `PUT` | `/api/alerts/:id/draft` | update draft (send `expected_lock_version`; `409` on conflict) |
| `POST` | `/api/alerts/:id/submit` | submit for review |
| `POST` | `/api/alerts/:id/review` | record review decision |
| `POST` | `/api/alerts/:id/publish` | publish approved version |
| `POST` | `/api/alerts/:id/correct` | issue a correction |
| `POST` | `/api/alerts/:id/cancel` | issue a cancellation |
| `GET` | `/api/alerts/:id/versions` | list immutable versions |
| `GET` | `/api/alerts/:id/versions/:n/xml` | published CAP XML |
| `GET` | `/api/alerts/:id/audit` | audit trail |
| `POST` | `/api/alerts/import` | import CAP XML as a new alert |
