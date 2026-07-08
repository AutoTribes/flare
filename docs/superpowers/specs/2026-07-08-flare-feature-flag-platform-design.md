# Flare — Feature Flag Platform: Architecture & Design Spec

**Status:** Approved architecture, ready for implementation planning
**Date:** 2026-07-08
**Author:** Erick (with Claude)

> "Flare" is a working name in the beacon/signal family. It is used as the OTP
> app name (`flare`), web app (`flare_web`), and root module (`Flare`) throughout
> this document. Renaming later is a mechanical find/replace; nothing in the
> design depends on the name.

---

## 1. Purpose & Product Thesis

Flare is an open-source, self-hostable **feature-flag and dynamic-configuration
platform** — a LaunchDarkly alternative — usable by multiple organizations and
multiple applications from a single deployment.

The core thesis is **separate deployment from release**:

- Applications deploy code once.
- Whether a feature is enabled, rolled out, targeted, or reconfigured is decided
  entirely from the dashboard.
- The dashboard pushes changes to connected SDKs in **real time**.
- SDKs evaluate flags **locally**. No SDK makes an HTTP request per evaluation.

This is built as a real, maintainable product for a large engineering team — not
a demo. It follows Elixir/OTP best practices and leans on Phoenix LiveView
wherever a UI is involved.

### Non-goals (explicit YAGNI)

- No experimentation/A-B statistical analysis engine in v1 (rollouts yes, metric
  attribution no).
- No approval-workflow / change-request state machine in v1 (audit log yes,
  multi-stage approvals no).
- No in-app billing.
- No data-warehouse pipeline for evaluation analytics in v1 (sampled telemetry to
  Redis is the ceiling; ClickHouse/warehouse is a later increment, out of scope
  here).

---

## 2. Tech Stack

**Backend:** Elixir, Phoenix, Phoenix LiveView, Phoenix PubSub, Ecto,
PostgreSQL, Redis, Oban, Finch, Bandit, Jason.

**Frontend:** Phoenix LiveView, TailwindCSS, DaisyUI. Alpine.js only where
LiveView genuinely cannot express an interaction (target: zero).

**Deployment:** Docker, Docker Compose, Kubernetes, GitHub Actions.

**Observability:** OpenTelemetry, `:telemetry` → Prometheus, structured JSON
logging.

---

## 3. Application Structure

**Single Phoenix application** (not an umbrella). Rationale: modern Phoenix
guidance favors a single app with well-bounded contexts unless there is a hard
requirement for separate OS processes or independent release cadence. Contexts
give us the domain boundaries; an umbrella would add ceremony and slow iteration
without buying isolation we need. Contexts can be extracted into their own apps
later if scaling demands it.

```
lib/flare/
  accounts/        # Organizations, Users, Memberships, authentication, RBAC
  projects/        # Projects, Environments, SDK keys, API keys
  flags/           # FeatureFlags, Variants, per-env settings, versions, archive
  segments/        # Reusable targeting groups
  targeting/       # Rule engine: JSON rule schema, compiler, operator library
  evaluation/      # The evaluator: (ruleset, flag, context) -> decision. Pure.
  sync/            # SSE handlers, ConnectionRegistry, PubSub fan-out, ruleset cache
  audit/           # Audit log write path (Oban) + queries
  observability/   # Telemetry handlers, metrics, tracing wiring
lib/flare_web/
  live/            # Dashboard LiveViews
  components/      # Reusable LiveComponents (rule builder, simulator, tables…)
  controllers/     # SDK streaming + REST API, health/ready
  plugs/           # SDK-key auth, API-key auth, rate limiting
```

### Boundary rules

- Contexts expose **public functions**; they never reach into another context's
  Ecto schemas or `Repo` directly.
- `Flare.Evaluation` is **pure**: it depends only on a ruleset value handed to it
  and a context map. No `Repo`, no Redis, no HTTP on the evaluation path. This is
  what makes it (a) sub-millisecond, (b) trivially testable, and (c) the exact
  same code the SDKs run.
- `Flare.Sync` owns all realtime/connection concerns; the rest of the system
  interacts with it only by broadcasting via PubSub and by asking it to build a
  ruleset snapshot.

---

## 4. Bounded Contexts

### 4.1 Accounts
Organizations, Users, Memberships, authentication, roles, permissions.

- **Organization** — the top-level tenant. Everything else is scoped under an org.
- **User** — a human. Can belong to multiple orgs via memberships.
- **Membership** — `user ↔ organization` with a `role`.
- **Role / Permission** — RBAC. A role owns a permission set; permissions can be
  scoped to the org, a project, or an environment (see §12 Security).
- **Auth** — session-based for the dashboard (`phx.gen.auth`-style), separate from
  SDK-key and API-key auth which the API layer handles.

### 4.2 Projects
Each organization owns multiple projects. A project contains environments,
feature flags, segments, and SDK keys.

- **Project** — belongs to an org.
- **Environment** — dev / testing / staging / production (and custom ones).
  Belongs to a project. **Owns a monotonic `ruleset_version` integer** that is
  bumped on every change affecting evaluation in that environment. This version
  is the linchpin of SDK sync/replay.
- **SDK Key** — belongs to an environment. See §12.
- **API Key** — belongs to an org, scoped permissions. See §12.

### 4.3 Feature Flags
Supports three kinds:

- **Boolean** — on/off (two variants).
- **Multivariate** — N string/number variants.
- **JSON configuration** — arbitrary JSON payloads as variants (e.g.
  `pricing_configuration`, `search_algorithm`).

A flag definition (key, kind, variants, description, tags, owner) lives at the
**project** level. Its **behavior is per-environment** (`enabled`, rules,
rollout, default variant) via `flag_environment_settings`. This is what makes
"each environment has independent values" literally true.

Example flags: `payment_v2` (boolean), `driver_navigation` (multivariate),
`pricing_configuration` (JSON), `search_algorithm` (multivariate).

### 4.4 Segments
Reusable user groups defined by rules, referenced from multiple flags. Example:
"VIP Drivers" = `country == "UG" AND trips > 500 AND verified == true`. A segment
change propagates to every flag that references it (via ruleset rebuild).

### 4.5 Targeting (Rule Engine)
Owns the JSON rule schema, the compiler that turns stored JSON into an evaluable
form, and the operator library. See §7.

### 4.6 Evaluation
The hot path. `evaluate(ruleset, flag_key, context) -> %Decision{}`. See §6.

### 4.7 Sync
SSE connection handlers, connection registry, PubSub fan-out, ruleset cache,
replay. See §8.

### 4.8 Audit
Every mutation writes an audit entry through Oban (never blocks the request).
Provides the query API for the audit-log page and per-flag audit timeline.

### 4.9 Observability
Telemetry handlers, Prometheus metric definitions, OTel span wiring, health
checks.

---

## 5. Data Model (Ecto Schemas & Migrations)

All tables carry `organization_id` (directly or transitively) and every context
query filters by it — organization isolation is enforced at the query layer, not
hoped for.

| Table | Key fields | Notes |
|---|---|---|
| `organizations` | `name`, `slug` | Top-level tenant |
| `users` | `email`, `hashed_password`, `name` | Global identity |
| `memberships` | `user_id`, `organization_id`, `role_id` | user↔org, carries role |
| `roles` | `organization_id`, `name`, `builtin` | e.g. owner/admin/member/viewer |
| `permissions` | `role_id`, `action`, `scope_type`, `scope_id` | RBAC grants |
| `projects` | `organization_id`, `name`, `slug` | |
| `environments` | `project_id`, `name`, `key`, `ruleset_version` | monotonic version |
| `feature_flags` | `project_id`, `key`, `kind`, `description`, `tags[]`, `owner_id`, `archived_at` | definition-level |
| `feature_variants` | `feature_flag_id`, `key`, `value` (jsonb), `name` | the possible values |
| `flag_environment_settings` | `feature_flag_id`, `environment_id`, `enabled`, `rules` (jsonb), `rollout` (jsonb), `default_variant_id`, `off_variant_id` | **per-env behavior** |
| `segments` | `project_id`, `key`, `name`, `rules` (jsonb) | reusable |
| `sdk_keys` | `environment_id`, `kind` (`server`/`client`/`mobile`), `hashed_secret`, `prefix`, `last_used_at`, `rotated_at`, `expires_at` | secret hashed at rest |
| `api_keys` | `organization_id`, `hashed_secret`, `prefix`, `permissions` (jsonb), `rotated_at`, `expires_at` | |
| `flag_versions` | `feature_flag_id`, `environment_id`, `version`, `snapshot` (jsonb), `diff` (jsonb), `changed_by_id`, `change_type` | immutable changelog — powers audit timeline **and** SDK delta replay |
| `audit_logs` | `organization_id`, `actor_id`, `action`, `entity_type`, `entity_id`, `before` (jsonb), `after` (jsonb), `metadata`, `inserted_at` | org-scoped |
| `evaluations` (optional) | sampled: `flag_key`, `environment_id`, `variant`, `reason`, `bucket`, `at` | telemetry sink; NOT on the hot path; Redis/ClickHouse later |

**Indexing highlights:** unique `(project_id, key)` on flags; unique
`(feature_flag_id, environment_id)` on settings; unique
`(environment_id, version)` on flag_versions; `sdk_keys.prefix` and
`api_keys.prefix` indexed for O(1) lookup by the leading public prefix before
verifying the hashed remainder.

---

## 6. Evaluation Engine

### 6.1 Contract
```elixir
Flare.Evaluation.evaluate(ruleset, flag_key, context) :: %Flare.Evaluation.Decision{}
```

`%Decision{}`:
- `value` — the resolved variant value (boolean / string / number / JSON)
- `variant` — variant key
- `enabled` — boolean convenience for boolean flags
- `matched_rule_id` — which rule matched (nil if fallthrough/default)
- `reason` — one of `:off | :prerequisite_failed | :target_match | :rule_match |
  :segment_match | :rollout | :fallthrough | :default | :flag_not_found`
- `bucket` — the computed rollout bucket (nil unless a rollout was consulted)

### 6.2 Ruleset
The evaluator operates only on an **in-memory compiled ruleset** for one
environment: a map of `flag_key => compiled_flag`, with segments already inlined.
The same ruleset shape is what the sync layer ships to SDKs, so server and SDK
run identical logic. Building a ruleset is a `Flare.Sync`/`Flare.Flags`
responsibility; evaluating it has zero I/O.

### 6.3 Evaluation order (per flag)
1. If `enabled == false` → off variant, reason `:off`.
2. Prerequisite flags (if any) — if unmet, `:prerequisite_failed`.
3. Individual target lists (explicit user IDs) → `:target_match`.
4. Rules in order; first match wins. A rule may resolve to a variant directly or
   to a **percentage rollout** → `:rule_match` / `:rollout` / `:segment_match`.
5. Fallthrough (default rule) → `:fallthrough`, possibly with its own rollout.
6. If flag missing from ruleset → `:flag_not_found`, caller-provided default.

### 6.4 Deterministic percentage rollout
**Never random.** Cross-language parity is a hard requirement because every SDK
(Elixir, Node, JS, Flutter, …) must compute the *identical* bucket for the same
input, forever.

- Hash: **MurmurHash3 (x86 32-bit)** — chosen for ubiquitous, well-specified
  implementations in every target language, guaranteeing byte-for-byte parity.
  (xxHash is an acceptable alternative; MurmurHash3 is the decision because it is
  what LaunchDarkly-style SDKs standardized on and has the widest audited
  cross-language support.)
- Bucketing key: `context.bucketing_key` (defaults to user id; configurable per
  flag, e.g. bucket by `organization` for org-wide rollout).
- Formula:
  ```
  hash_input = "#{flag_key}:#{rollout_salt}:#{bucketing_key}"
  h          = murmur3_32(hash_input)
  bucket     = rem(h, 100_000) / 1000.0      # 0.000 .. 99.999 (fine-grained)
  ```
  A user is in the rollout if `bucket < rollout_percentage`. Coarse variants use
  `rem(h, 100)`. `rollout_salt` is stable per flag (stored) so changing rollout %
  keeps users' buckets stable, and re-salting is an explicit deliberate action.
- **Conformance fixtures:** a language-agnostic JSON fixture file
  (`(input, expected_hash, expected_bucket)` tuples) lives in the repo. Every SDK
  has a test that runs these fixtures. This is the contract that guarantees a
  user always gets the same variation everywhere.

### 6.5 Performance
Target **< 1 ms** per evaluation. Achieved by: pure in-memory data, precompiled
rules, inlined segments, no allocation-heavy work, first-match short-circuit.
Property-based tests assert determinism (same input → same output) and the
distribution of buckets is uniform.

---

## 7. Rule Engine (JSON + Visual Builder)

### 7.1 Storage format
Rules are JSONB. Nested AND/OR to arbitrary depth. A leaf is either an attribute
condition or a segment reference.

```json
{
  "op": "and",
  "conditions": [
    { "op": "or", "conditions": [
        { "attr": "country", "operator": "in", "values": ["KE", "UG"] },
        { "segment": "beta-users" }
    ]},
    { "attr": "app_version", "operator": "semver_gte", "values": ["5.2.0"] }
  ]
}
```

### 7.2 Targetable attributes
`user_id`, `email`, `country`, `city`, `role`, `app_version`, `device`,
`operating_system`, `organization`, and arbitrary **custom attributes** (any key
in `context.custom`).

### 7.3 Operators
`equals`, `not_equals`, `contains`, `starts_with`, `ends_with`, `gt`, `lt`,
`gte`, `lte`, `regex`, `in` (in list). Plus `semver_eq/gt/lt/gte/lte` for version
comparisons (app_version is semver, not string). Each operator is a pure function
in the operator library with its own unit tests, including type coercion and
missing-attribute behavior (missing attribute → condition is false, never
crashes).

### 7.4 Segment inlining
`{ "segment": "beta-users" }` is resolved at **ruleset build time** — the
segment's rules are inlined into the compiled flag. This keeps evaluation flat
and fast while preserving real reuse: editing a segment rebuilds every dependent
flag's compiled form and bumps affected environment versions.

### 7.5 Visual rule builder
A `LiveComponent` that renders and edits this JSON. **The JSON is the single
source of truth**; the builder is a bidirectional view. Users can also drop to a
raw JSON editor. Validation runs on every change (unknown operator, malformed
semver, dangling segment reference → inline errors).

---

## 8. Sync Layer (SDK Realtime — Adapted from `beacon`)

The realtime design is grounded in the production `beacon` SSE service
(`C:\dev\personal\beacon`). Beacon solved SSE fan-out at scale; we reuse its
proven patterns and **simplify** where feature-flag sync is inherently easier.

### 8.1 Why this is simpler than beacon
Beacon fans out **millions of distinct per-user event streams** (hence its Redis
`XREAD` sharding across `StreamReader` processes). Flare fans out **a handful of
environment rulesets**, each to many subscribers. So:

- No Redis Streams needed for flag sync. Source of truth is Postgres (a versioned
  ruleset per environment).
- Redis is used only for: (a) the prebuilt ruleset JSON cache SDKs download,
  (b) rate-limit counters, (c) optionally the cross-node PubSub backend.

### 8.2 Patterns reused from beacon
- **Per-connection GenServer** (`Flare.Sync.SSEHandler`) owns one SSE stream,
  subscribes to a PubSub topic, and does **zero datastore I/O**. (Beacon's
  `SSEHandler`.)
- **`Flare.Sync.ConnectionRegistry`** — ETS bag keyed by connection identity with
  a monotonic timestamp, for per-SDK-key connection counts, telemetry, and
  "evict oldest" when a cap is exceeded. (Beacon's `ConnectionRegistry`.)
- **Heartbeat** (~25 s) to keep proxies/load balancers from killing idle SSE
  connections; refreshes presence/telemetry.
- **Mailbox backpressure**: on each event, check `message_queue_len`; if it
  exceeds a threshold, disconnect the client — it reconnects with its
  `Last-Event-ID` and catches up. (Beacon's overload guard.)
- **Replay via `Last-Event-ID`** — beacon uses a composite Redis-stream cursor;
  Flare uses the **environment `ruleset_version`** (cleaner, because flag config
  is a versioned snapshot, not an append-only event log).
- **Default-to-catch-up on connect** — like beacon's "cursor defaults to 0, not
  $" invariant: if the SDK's version is behind, we push immediately rather than
  risk dropping an update that landed during the connect race.

### 8.3 Write → broadcast flow
```
Dashboard mutates a flag/segment/rule
  → Flags/Segments context (single transaction):
      - update flag_environment_settings
      - bump environment.ruleset_version
      - insert flag_versions row (snapshot + diff)
      - enqueue audit log (Oban)
  → rebuild the environment's compiled ruleset, write JSON to Redis cache
  → Phoenix.PubSub.broadcast("env:{env_id}", {:ruleset_updated, version})
  → each SSEHandler subscribed to "env:{env_id}" pushes an SSE event
  → dashboard LiveViews subscribed to the same topic update with no refresh
```

The **dashboard and the SDKs subscribe to the exact same PubSub topic** — so the
dashboard's own realtime updates and SDK updates are driven by one mechanism.

### 8.4 SDK protocol
- **Auth:** `Authorization: Bearer <sdk_key>` (or client-key query param for
  browser). The prefix identifies the key; the remainder is verified against the
  stored hash.
- **Bootstrap:** `GET /sdk/ruleset` → `{ version, flags, segments }` full
  snapshot (served from Redis cache). SDKs may also bootstrap from a
  caller-supplied blob (offline / server-rendered) via `bootstrap()`.
- **Stream:** `GET /sdk/stream` (SSE) with `Last-Event-ID: <version>`. On connect,
  if `env.ruleset_version > client_version`, the server sends the current ruleset
  (a `flag_versions` delta if the gap is small, else a full snapshot) immediately,
  then streams live `put`/`patch`/`delete` events. Heartbeats keep it alive.
- **Polling fallback:** `GET /sdk/ruleset?version=N` → `304 Not Modified` if
  unchanged, else the new ruleset. For environments/proxies where SSE is
  unavailable. SDKs poll on a configurable interval.
- **Local evaluation:** all `is_enabled`/`variation`/`json` calls run entirely
  against the in-memory cached ruleset using the shared evaluation logic. Zero
  network per evaluation.

### 8.5 Scale
- Each SSE connection ≈ a small BEAM process (a few KB). 100k connections per node
  is within BEAM limits; horizontal scale adds nodes.
- Cross-node fan-out: Phoenix.PubSub via the PG2 adapter (default) or a Redis
  adapter at very large scale. Reconnect storms hit the Redis ruleset cache, not
  Postgres.
- HPA scales on connection count / CPU. SSE-friendly ingress timeouts required.

---

## 9. Dashboard (Phoenix LiveView)

### 9.1 Pages
Dashboard (overview), Organizations, Projects, Environments, Feature Flags
(list), Feature Flag detail, Segments, SDK Keys, API Keys, Audit Logs, Users,
Roles, Settings. A **global environment selector** in the top bar scopes flag
views to one environment.

### 9.2 Feature Flag list
Search, sorting, filtering, pagination (LiveView streams + keyset/offset Ecto
queries). Bulk enable / disable / archive. Columns: name, owner, status, last
updated, environment value. Archive is a soft state (`archived_at`), archived
flags hidden by default and filterable back in.

### 9.3 Feature Flag detail
General info (description, tags, status toggle), **per-environment values**, the
**visual rule builder**, a **percentage rollout slider**, variants editor, JSON
editor (for JSON flags / raw rules), segment attach/detach, explicit target-user
lists, the **evaluation simulator**, and the **audit timeline** (from
`flag_versions` + `audit_logs`). Everything is realtime: the LiveView subscribes
to `env:{id}` and reflects changes made by teammates without a refresh.

### 9.4 Evaluation Simulator
A `LiveComponent` where you enter a context (user id, country, role, app version,
custom attributes) and get back: matched rule(s), computed bucket, winning
variant, and the full reason chain. It calls the **exact same**
`Flare.Evaluation.evaluate/3` the SDKs use — so the simulator cannot disagree
with production.

### 9.5 Reusable LiveComponents
`RuleBuilder`, `EvaluationSimulator`, `FlagTable` (sort/filter/paginate/bulk),
`VariantEditor`, `RolloutSlider`, `JsonEditor`, `AuditTimeline`,
`EnvironmentSelector`, `KeyManager` (create/rotate/reveal-once).

### 9.6 Styling
Tailwind + DaisyUI, shadcn-inspired component composition. Alpine.js avoided;
LiveView + `phx-` bindings handle interactivity. Any unavoidable Alpine use is
documented and minimal.

---

## 10. APIs

### 10.1 SDK API (edge-facing, high volume)
- `GET /sdk/ruleset` — full snapshot (Redis-cached), supports `?version=N` → 304.
- `GET /sdk/stream` — SSE stream with `Last-Event-ID` replay.
- `POST /sdk/events` (optional, later) — SDKs report evaluation telemetry.
- Auth: SDK key. Rate limited. Server keys vs client keys expose different data
  (client keys never receive server-only flags/attributes).

### 10.2 REST management API (dashboard-equivalent, for automation/CI)
CRUD for projects, environments, flags, segments, keys; scoped by API key
permissions. Enables GitOps/Terraform-style management. Mirrors what the
dashboard does through the same contexts.

### 10.3 Documentation
OpenAPI spec generated for the REST + SDK API; per-language SDK READMEs; a
"getting started" guide.

---

## 11. SDKs

### 11.1 Shared contract
Every SDK exposes: `is_enabled()`, `variation()`, `json()`, `identify()`,
`refresh()`, `subscribe()`, `offline_mode()`, `bootstrap()`. All cache everything
locally and evaluate locally.

### 11.2 Common architecture (identical across languages)
1. **Init** → authenticate → `bootstrap` (from supplied data or `GET /sdk/ruleset`)
   → cache in memory.
2. **Stream** → open SSE; on event, update cache; auto-reconnect with
   `Last-Event-ID`; **poll** as fallback when SSE is unavailable.
3. **Evaluate locally** against the cached ruleset using the shared rule +
   MurmurHash3 logic — the conformance-tested core.
4. `identify()` sets/updates the evaluation context; `offline_mode()` evaluates
   from a bootstrap blob with no network; `subscribe()` registers change
   callbacks.

### 11.3 Targets & order
Elixir (first — in-repo, end-to-end testable, **reference implementation**) →
Node.js → NestJS (wrapper over the Node core) → Browser JavaScript (client key,
no server secrets, SSE via `EventSource` + polling fallback) → Flutter. Each is
its own package/repo/release lifecycle and each ships the conformance-fixture
test.

---

## 12. Security

- **RBAC** — roles own permission sets; permissions carry a `scope_type`
  (`org` / `project` / `environment`) and `scope_id`. Every context function
  checks the actor's permission for the target scope. Built-in roles:
  owner, admin, member, viewer; custom roles allowed.
- **Isolation** — organization, project, and environment isolation enforced in
  every query (scoped by `organization_id` / `project_id` / `environment_id`),
  not just in the UI.
- **SDK & API keys** — a public `prefix` (indexed, for lookup) + a secret
  remainder that is **hashed at rest** (Argon2/bcrypt). The full secret is shown
  **once** at creation and never retrievable again. **Rotation** issues a new
  secret with a grace window where both old and new validate, then the old is
  revoked. `expires_at` supported.
- **Rate limiting** — Redis token-bucket plug on SDK and API endpoints, keyed by
  key id, with per-key limits.
- **Audit logging** — every mutation (who, what, before/after, when) written via
  Oban so it never blocks the request path; queryable per-org and per-flag.

---

## 13. Performance Goals

| Concern | Target | How |
|---|---|---|
| Flag evaluation | < 1 ms | pure in-memory compiled ruleset, no I/O |
| Dashboard response | < 200 ms | LiveView, scoped indexed queries, streams |
| Connected SDK clients | 100,000 | lightweight per-conn BEAM process, multi-node |
| Evaluations/day | millions | evaluations happen in the SDK, not on our servers |
| Scaling | horizontal | stateless web nodes, PubSub fan-out, Redis cache |

The key architectural fact: **evaluations do not hit Flare's servers at all** —
they happen inside each SDK against its local cache. Flare's servers handle
config management and change fan-out, both of which are low-volume relative to
evaluation traffic.

---

## 14. Observability

- **OpenTelemetry** traces across web requests, context calls, sync fan-out.
- **`:telemetry` → Prometheus** metrics: evaluation timings (in SDKs, reported
  optionally), connection counts, fan-out latency, ruleset build time, cache hit
  rate, rate-limit rejections.
- **Structured JSON logging** with request/trace correlation IDs.
- **Health checks** — `/health` (liveness) and `/ready` (readiness: DB + Redis +
  PubSub reachable).
- **Telemetry dashboards** — Phoenix LiveDashboard for ops; Prometheus/Grafana
  manifests provided.

---

## 15. Deployment & Infra

- **Docker** — multi-stage build producing a slim OTP release (Bandit server).
- **Docker Compose** — app + Postgres + Redis for local development and demos.
- **Kubernetes** — Deployment, Service, Ingress (SSE-friendly timeouts), HPA
  (scale on connection count / CPU), ConfigMap/Secret, migration Job, and
  Postgres/Redis as managed services or StatefulSets.
- **GitHub Actions** — CI: compile (warnings as errors), `credo`, `dialyzer`,
  `mix test` (with Postgres+Redis services), format check, conformance fixtures;
  CD: build/push image, deploy manifests.
- **Production deployment guide** — runtime config via env, secret handling, DB
  migrations, scaling guidance, backup/restore, upgrade path.

---

## 16. Testing Strategy

- **Evaluation & rules** — exhaustive unit tests per operator; **property-based
  tests** for determinism (same input → same output) and rollout uniformity;
  the **cross-language conformance fixtures**.
- **Contexts** — unit tests with `Ecto.Sandbox`; isolation tests proving an org
  can never read another org's data.
- **Sync** — unit tests for `SSEHandler`/`ConnectionRegistry` (mirroring beacon's
  test suite: register/evict/backpressure/replay), plus an integration test:
  mutate flag → PubSub → SSEHandler → SSE chunk received with correct version.
- **Dashboard** — LiveView tests for each page and component (rule builder round-
  trips JSON, simulator matches the engine, bulk actions, realtime updates).
- **SDKs** — each SDK runs the conformance fixtures + protocol tests
  (bootstrap/stream/reconnect/poll/offline) against a running server.
- **CI gates** — everything above runs in GitHub Actions on every PR.

---

## 17. Build Order (Increment Roadmap)

Each increment is independently shippable and gets its own detailed
implementation plan section. The full plan (all increments) is written up front
per the project decision, with the understanding that later increments may be
refined as earlier ones teach us things.

1. **Increment 1 — Core & Evaluation Engine.** Contexts (accounts, projects,
   flags, segments, targeting, evaluation), Ecto schemas + migrations, the rule
   compiler + operator library, deterministic MurmurHash3 bucketing, the
   cross-language conformance fixtures, and a full unit/property test suite. No
   UI, no network. *This is the foundation everything depends on and the hardest
   part to get right.*
2. **Increment 2 — Sync Layer, REST/SDK API, Elixir SDK.** Ruleset builder +
   Redis cache, SSE handlers + ConnectionRegistry (beacon patterns), replay via
   version, polling fallback, REST management API, and the reference Elixir SDK
   with an end-to-end test.
3. **Increment 3 — LiveView Dashboard.** All pages, the reusable components
   (rule builder, simulator, flag table, key manager), realtime via PubSub.
4. **Increment 4 — Security Hardening.** RBAC depth + scope enforcement tests,
   key rotation with grace windows, rate limiting, audit-log completeness.
5. **Increment 5 — Remaining SDKs.** Node → NestJS → Browser JS → Flutter, one at
   a time, each passing the conformance fixtures + protocol tests.
6. **Increment 6 — Infra & Observability.** Dockerfile, docker-compose, K8s
   manifests, GitHub Actions CI/CD, OpenTelemetry/Prometheus wiring, health
   checks, and the production deployment guide.

---

## 18. Key Risks & Blind Spots (Candid)

- **Cross-language hash parity is the highest-risk detail.** If MurmurHash3
  differs by a byte between two SDKs, users get different variations across
  platforms and it will be maddening to debug. Mitigation: the conformance
  fixtures are authored in Increment 1 and are a hard CI gate for every SDK.
- **SSE at 100k connections** needs real load testing; the beacon patterns are
  proven but Flare's per-environment topic model is different enough to warrant
  its own load test (Increment 2/6).
- **Ruleset rebuild cost** on segment edits that fan out to many flags could
  spike; mitigation: rebuild is async where possible and cached, and we measure
  build time as a telemetry metric.
- **Client-key data leakage** — browser/mobile client keys must never receive
  server-only flags or attribute definitions; the ruleset builder must filter by
  key kind. This is a security-critical branch that needs explicit tests
  (Increment 2 + 4).
- **RBAC scope explosion** — env-scoped permissions add real complexity; we keep
  built-in roles simple and treat custom fine-grained roles as an advanced,
  well-tested path (Increment 4).
- **Scope creep toward LaunchDarkly parity** — experimentation, approval
  workflows, and analytics pipelines are explicitly deferred (non-goals) to keep
  v1 shippable.

---

## 19. Multidimensional Evaluation

- **Scalability:** Strong. Evaluations happen client-side; servers do config +
  fan-out only. Stateless web tier, PubSub fan-out, Redis cache, HPA. The one
  thing to watch is per-node SSE connection count (mitigated by horizontal scale).
- **Performance:** Strong. Sub-ms eval by construction (pure in-memory);
  dashboard <200ms via scoped indexed queries + LiveView streams.
- **Security:** Good, with explicit hard edges — org/project/env isolation at the
  query layer, hashed keys with rotation, client-key data filtering, rate
  limiting, full audit. RBAC scope model is the most complex surface and is
  tested accordingly.
- **UX (dashboard):** Strong. Realtime everywhere via one PubSub mechanism, a
  visual rule builder backed by canonical JSON, and a simulator that runs the
  real engine so it can't lie.
- **Maintainability:** Strong. Single app with hard context boundaries, a pure
  evaluation core, one shared SDK contract, conformance fixtures as the
  cross-language contract. Beacon patterns are already understood by the team.
- **Reliability:** Strong. OTP supervision, backpressure, reconnect-with-replay,
  crash-recovery re-registration, audit via Oban (durable, non-blocking).
- **Accessibility:** Addressed at the component layer (semantic markup, keyboard
  nav, focus management, contrast) — called out as a dashboard requirement rather
  than an afterthought.

**Trade-offs consciously accepted:**
- Single app over umbrella — simpler DX, we forgo hard process isolation we don't
  need yet.
- SSE over WebSocket/Channels — simpler, HTTP-native, scales for a push-only
  read-mostly workload; we forgo bidirectional messaging we don't need for sync.
- Snapshot-version replay over an event log — simpler and correct for versioned
  config; we forgo fine-grained event replay we don't need.
- Deferring experimentation/analytics — keeps v1 focused; we forgo LaunchDarkly
  feature parity in exchange for a shippable, correct core.
