# Flare Increments 2–6 — Task-Level Roadmap

> **For agentic workers:** This roadmap is intentionally at **task granularity**, not
> bite-sized-step granularity. Each increment gets expanded into a full
> bite-sized TDD plan (via superpowers:writing-plans) **just before it is
> executed**, so its tasks reflect what earlier increments actually produced.
> This avoids planning speculative code (SDK internals, K8s manifests) against an
> API surface that Increment 1/2 is still shaping. Each increment produces
> working, testable software on its own.

Refer to the design spec: `docs/superpowers/specs/2026-07-08-flare-feature-flag-platform-design.md`.

---

## Increment 2 — Sync Layer, REST/SDK API, Elixir SDK

**Goal:** A running server that hashes SDK keys, serves ruleset snapshots from a
Redis cache, streams realtime updates over SSE with version-based replay, offers
a polling fallback, exposes a REST management API, and ships a reference Elixir
SDK — with an end-to-end test proving a flag change reaches a connected SDK.

**Depends on:** Increment 1 (`Flare.Evaluation`, `Flare.Flags.build_ruleset/1`, all schemas).

**Reuse:** `beacon` patterns (`C:\dev\personal\beacon`) — `SSEHandler`,
`ConnectionRegistry`, heartbeat, mailbox backpressure. See spec §8.2.

### Tasks
1. **Redis + Finch + Oban wiring.** Add `redix`, `finch`, `oban` deps; add
   `Flare.Redis` (pooled, non-blocking only) and Oban config; supervision tree
   entries. Test: Redis round-trip, Oban boots.
2. **SDK key hashing + verification.** `Flare.Projects.generate_sdk_key/2`
   returns `{prefix, plaintext, %SdkKey{}}`; `verify_sdk_key/1` looks up by
   prefix and verifies the hashed remainder (Argon2). Full secret shown once.
   Test: create → verify success; wrong secret → fail; unknown prefix → fail.
3. **Ruleset cache + serialization.** `Flare.Sync.RulesetCache` builds the
   compiled ruleset (Increment 1) → serializes to the SDK JSON wire shape
   (`%{version, flags, segments}`, client-key filtering per §8.4) → writes Redis
   `flare:ruleset:{env_id}` with the version. `get/1` returns cached JSON or
   rebuilds on miss. Test: build → cache → get returns identical; client key
   excludes server-only flags.
4. **Version bump + broadcast on flag change.** Extend `Flare.Flags` mutations to
   run in one transaction: update setting → bump `environment.ruleset_version` →
   insert `flag_versions` row (snapshot + diff) → enqueue audit (Oban) →
   rebuild+cache ruleset → `Phoenix.PubSub.broadcast("env:{id}", {:ruleset_updated, version})`.
   Test: mutation increments version, writes flag_version, broadcasts once.
5. **`Flare.Sync.ConnectionRegistry`** (port of beacon's): ETS bag keyed by
   `(sdk_key_id, connection_id)` + monotonic ts; `register/unregister/count`,
   `evict_oldest/1` for per-key connection cap. Test: register/lookup/evict/count
   (mirror beacon's `connection_registry_test.exs`).
6. **`Flare.Sync.SSEHandler`** (port of beacon's, simplified — no Redis reads):
   per-connection GenServer; subscribes `env:{env_id}`; on `{:ruleset_updated, v}`
   pushes SSE `put`/`patch`; heartbeat ~25s; mailbox backpressure guard;
   `terminate/2` unregisters. Test: subscribe → broadcast → chunk received;
   overloaded mailbox → close.
7. **SSE controller + replay.** `GET /sdk/stream` plug-authed by SDK key; reads
   `Last-Event-ID` (= client version); if `env.ruleset_version > client_version`,
   sends current ruleset immediately (delta from `flag_versions` if small, else
   full), then attaches the SSEHandler. Bandit streaming response. Test: connect
   with stale version → immediate catch-up event; connect current → only
   heartbeats until a change.
8. **Ruleset REST endpoint + polling fallback.** `GET /sdk/ruleset` (full, cached)
   and `GET /sdk/ruleset?version=N` → `304` if unchanged. Test: 200 with body;
   304 when version matches.
9. **REST management API.** Controllers for projects/environments/flags/segments/
   keys CRUD, authed by API key + scoped permissions (permission checks stubbed
   to org-level in this increment, deepened in Increment 4). OpenAPI spec stub.
   Test: create flag via API → appears in ruleset.
10. **Rate-limiting plug.** Redis token-bucket keyed by key id on `/sdk/*` and
    `/api/*`. Test: over-limit → 429.
11. **Reference Elixir SDK** (`Flare.SDK` module or a separate `flare_sdk` mix
    package in `sdks/elixir/`): `start_link` (auth + bootstrap + connect),
    `is_enabled/variation/json/identify/refresh/subscribe/offline_mode/bootstrap`;
    caches ruleset in an Agent/GenServer; evaluates locally via
    `Flare.Evaluation`; SSE client via Finch with auto-reconnect + `Last-Event-ID`;
    polling fallback. Test: bootstrap → evaluate offline; identify changes context.
12. **End-to-end integration test.** Start server, connect Elixir SDK, mutate a
    flag through the context, assert the SDK observes the new variation within N
    ms. This is the increment's acceptance gate.

**Acceptance:** flag change in DB → PubSub → SSE → SDK cache updated → local
evaluation reflects it, end to end, in a test. Polling fallback verified. SDK
keys hashed at rest.

---

## Increment 3 — LiveView Dashboard

**Goal:** The full enterprise dashboard, realtime via the same PubSub topics the
SDKs use, with a visual rule builder and a simulator that runs the real engine.

**Depends on:** Increments 1–2. Needs session auth (added here).

### Tasks
1. **Session auth** via `phx.gen.auth` (users/sessions), org-scoped current-user
   assigns, org/project/environment selectors in a shared layout.
2. **App shell + navigation** — DaisyUI layout, sidebar, global environment
   selector LiveComponent, breadcrumb.
3. **Dashboard overview page** — counts, recent audit activity, per-env flag
   status summary.
4. **Organizations / Projects / Environments pages** — list + create + edit
   LiveViews.
5. **Feature Flag list LiveView** — LiveView streams; search, sort, filter,
   pagination; bulk enable/disable/archive; columns owner/status/last-updated;
   realtime updates via `env:{id}` subscription.
6. **`FlagTable` LiveComponent** — extracted reusable table (sort/filter/
   paginate/bulk selection).
7. **Feature Flag detail LiveView** — general info, tags, status toggle, per-env
   values, subscribes to `env:{id}` for live teammate updates.
8. **`RuleBuilder` LiveComponent** — visual nested AND/OR builder that reads/
   writes the canonical rule JSON (Increment 1 shape); validates on change;
   raw-JSON escape hatch.
9. **`VariantEditor` + `RolloutSlider` + `JsonEditor` LiveComponents.**
10. **`EvaluationSimulator` LiveComponent** — form (user id/country/role/app
    version/custom) → calls `Flare.Evaluation.evaluate/3` → shows matched rule,
    bucket, winning variant, reason chain.
11. **Segments pages** — list/create/edit with the same `RuleBuilder`.
12. **SDK Keys / API Keys pages** — `KeyManager` LiveComponent (create → reveal
    once → rotate → revoke).
13. **Audit Logs page + per-flag `AuditTimeline` LiveComponent** — from
    `audit_logs` + `flag_versions`.
14. **Users / Roles / Settings pages.**
15. **Accessibility pass** — semantic markup, keyboard nav, focus management,
    contrast; LiveView tests assert key a11y attributes.

**Acceptance:** every spec §9 page exists and works; rule builder round-trips
JSON; simulator agrees with the engine; two browser sessions see each other's
changes with no refresh.

---

## Increment 4 — Security Hardening

**Goal:** Turn the stubbed permission checks into enforced, tested RBAC; complete
key rotation, rate limiting, and audit coverage.

**Depends on:** Increments 1–3.

### Tasks
1. **RBAC model completion** — built-in roles (owner/admin/member/viewer) seeded
   per org; `Flare.Accounts.can?/3` (actor, action, scope) checking permissions
   with `org/project/environment` scoping.
2. **Enforcement** — wrap every mutating context function and controller action
   with permission checks; LiveViews gate actions on `can?/3`.
3. **Isolation tests** — property/unit tests proving org A cannot read/mutate org
   B's projects/flags/keys/segments/audit at the context and API layers.
4. **Key rotation with grace window** — `rotate_sdk_key/1` / `rotate_api_key/1`
   issue a new secret; both validate during a configurable grace window; old
   revoked after. Tests for both-valid, post-grace-old-invalid.
5. **Client-key data filtering hardening** — explicit tests that client/mobile
   keys never receive server-only flags/attributes in the ruleset (spec §18 risk).
6. **Rate-limit tuning + per-key limits** — configurable, tested.
7. **Audit completeness** — every mutation writes an audit log (actor, before,
   after); coverage test enumerates mutating functions and asserts an audit row.

**Acceptance:** cross-org isolation proven in tests; rotation works with grace;
client keys leak nothing; every mutation is audited.

---

## Increment 5 — Remaining SDKs

**Goal:** Node.js, NestJS, Browser JS, and Flutter SDKs, each implementing the
shared contract and each passing the cross-language conformance fixtures from
Increment 1.

**Depends on:** Increments 1–2 (the wire protocol + fixtures). Each SDK is its
own package/repo under `sdks/`.

### Per-SDK task shape (repeat for each)
1. **Port MurmurHash3 + bucketing**; run `test/fixtures/hash_conformance.json` and
   `rollout_conformance.json` as tests. **Hard gate — must match byte-for-byte.**
2. **Port the rule engine** (operators, compiler, segment inlining, evaluation
   order) with unit tests mirroring Increment 1's.
3. **Client core** — auth, bootstrap (`GET /sdk/ruleset`), SSE stream with
   `Last-Event-ID` reconnect, polling fallback, local cache.
4. **Public contract** — `is_enabled / variation / json / identify / refresh /
   subscribe / offline_mode / bootstrap`.
5. **Protocol integration test** against a running Flare server (bootstrap /
   stream / reconnect / poll / offline).
6. **Package + README + release config.**

**Order:** Node.js → NestJS (thin wrapper over the Node core, DI module +
decorators) → Browser JS (client key only, `EventSource` + polling, no server
secrets, tree-shakeable, no Node deps) → Flutter (Dart; uses the platform's
Flutter toolchain per project memory; SSE via `http`/`dio`, offline cache via
local storage).

**Acceptance:** all four SDKs green on the conformance fixtures and protocol
tests; a user gets the identical variation across every SDK for the same context.

---

## Increment 6 — Infra & Observability

**Goal:** Production-ready packaging, deployment, CI/CD, and observability.

**Depends on:** Increments 1–5 (needs the running app + endpoints to instrument).

### Tasks
1. **OTP release + multi-stage Dockerfile** (Bandit; slim runtime image).
2. **docker-compose** — app + Postgres + Redis for local/dev/demo; healthchecks;
   seed task.
3. **Kubernetes manifests** — Deployment, Service, Ingress (SSE-friendly read
   timeouts + buffering off), HPA (scale on connection count / CPU),
   ConfigMap/Secret, DB migration Job, Postgres/Redis (managed or StatefulSet).
4. **GitHub Actions CI** — compile (`--warnings-as-errors`), `mix format --check`,
   `credo --strict`, `dialyzer`, `mix test` with Postgres+Redis services, and the
   conformance fixtures run against every SDK.
5. **GitHub Actions CD** — build/push image, deploy manifests (environment-gated).
6. **OpenTelemetry** — trace web requests, context calls, sync fan-out; exporter
   config.
7. **`:telemetry` → Prometheus** — evaluation timings, connection counts, fan-out
   latency, ruleset build time, cache hit rate, rate-limit rejections;
   Prometheus/Grafana manifests; LiveDashboard.
8. **Structured JSON logging** with trace correlation.
9. **Health checks** — `/health` (liveness), `/ready` (DB+Redis+PubSub).
10. **`evaluations` telemetry sink** (the optional §5 table / Redis) — sampled
    eval reporting endpoint `POST /sdk/events` + aggregation.
11. **Load test** — 100k SSE connections against the per-environment topic model
    (spec §18 risk); document results.
12. **Production deployment guide** — runtime env config, secrets, migrations,
    scaling, backup/restore, upgrade path.

**Acceptance:** `docker-compose up` runs the whole stack; CI is green on PRs;
K8s manifests deploy; metrics/traces/health verified; deployment guide complete;
load test documented.

---

## Cross-Increment Notes

- **Testing discipline (spec §16):** every increment is TDD; CI gates land in
  Increment 6 but `mix test` + `credo --strict` + `--warnings-as-errors` are run
  locally from Increment 1 onward.
- **The conformance fixtures (Increment 1, Task 4) are the spine of the whole
  product.** Increment 5's SDKs and Increment 2's server all trust them. Never
  regenerate them casually — a change there silently changes every user's
  bucketing across every platform.
- **Beacon is the reference for Increment 2's sync layer**, not a dependency — we
  port and simplify its patterns (spec §8.1–8.2).
- **Just-in-time expansion:** before starting an increment, run writing-plans on
  that increment's tasks to produce the bite-sized TDD plan, informed by the
  actual code shipped in prior increments.
