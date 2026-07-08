# Flare Increment 2 — Sync Layer, REST/SDK API, Elixir SDK — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox syntax. Run all mix in the container: `docker compose -f docker-compose.dev.yml exec -T app mix <args>`. `git` on host. NO host Elixir.

**Goal:** A running server that hashes SDK keys, serves versioned ruleset snapshots from a Redis cache, streams realtime updates over SSE with version-based replay + polling fallback, exposes a REST management API, and ships a reference Elixir SDK — proven by an end-to-end test where a flag change reaches a connected SDK.

**Architecture:** Source of truth = Postgres (versioned ruleset per environment). On a flag change we bump `environment.ruleset_version` in one transaction, write a `flag_versions` row, enqueue an audit log (Oban), rebuild the JSON payload into Redis, and `Phoenix.PubSub.broadcast("env:{id}", {:ruleset_updated, v})`. Per-connection SSE GenServers (beacon pattern) subscribe to that topic and push; they do NO datastore I/O. SDKs cache the payload and evaluate locally via the SAME `Flare.Evaluation` code (the Elixir SDK literally calls `Ruleset.build/3` + `Evaluation.evaluate/3`).

**Reuse from beacon** (`C:\dev\personal\beacon`): `SSEHandler` (per-conn GenServer, PubSub-subscribed, mailbox backpressure, heartbeat), `ConnectionRegistry` (ETS bag + monotonic ts + evict-oldest). Simplified: no Redis Streams / StreamReader sharding — we fan out a handful of env rulesets, not millions of per-user streams.

**Tech added:** `redix`, `oban`, `finch`, `argon2_elixir`.

---

## The SDK wire contract (pin this — it is what SDKs replicate)

`GET /sdk/ruleset` returns and SSE `put` events carry this JSON:
```json
{
  "version": 7,
  "flags": [
    {
      "key": "payment_v2", "kind": "boolean", "salt": "abc",
      "enabled": true,
      "rules": { "list": [ {"id":"r1","rule":{"attr":"country","operator":"equals","values":["KE"]},"variant":"off"} ] },
      "rollout": {}, "default_variant": "on", "off_variant": "off",
      "variants": {"on": true, "off": false},
      "targets": {}, "bucket_by": "user_id"
    }
  ],
  "segments": { "beta": {"op":"and","conditions":[ ... ]} }
}
```
- **Raw (un-inlined) rules + a segments map are shipped** — the SDK inlines segments locally via the same compiler. This keeps payloads small (segment reuse) and evaluation identical server/SDK.
- Both server (`build_ruleset`) and SDK build a compiled `Ruleset` from `flags` + `segments` via `Flare.Evaluation.Ruleset.build/3`.
- `Ruleset.build/3` takes flag maps with STRING or ATOM keys — the SDK/cache path uses string keys from JSON, so `Ruleset.build` and `to_flag_map` must accept string keys too (see Task 3).

---

## Task 2.1 — Dependencies + infra wiring (Redis, Oban, Finch, Argon2)
**Files:** `mix.exs`, `config/config.exs`, `config/runtime.exs`, `config/test.exs`, `lib/flare/application.ex`, `lib/flare/redis.ex`, migration for Oban.

- [ ] Add deps: `{:redix, "~> 1.5"}`, `{:oban, "~> 2.18"}`, `{:finch, "~> 0.19"}`, `{:argon2_elixir, "~> 4.0"}`. `mix deps.get`.
- [ ] `Flare.Redis` — a thin wrapper over a Redix pool (name `:flare_redix`, pool size from config). `command/1`, `command!/1`. Configure `REDIS_URL` (default `redis://redis:6379` in dev/test — the container host is `redis`).
- [ ] Oban: config `Oban` with the Repo and a queue `audit: 10`, `events: 20`. Generate the Oban migration (`mix ecto.gen.migration add_oban_jobs`, body `Oban.Migration.up/down`). Migrate.
- [ ] Add to supervision tree (after Repo, before Endpoint): `{Redix, ...}` pool, `{Oban, ...}`, `{Finch, name: Flare.Finch}`. Also `Flare.Sync.ConnectionRegistry` and `Flare.Sync.RulesetCache` come in later tasks.
- [ ] Test `test/flare/redis_test.exs`: `Flare.Redis.command!(["PING"]) == "PONG"`; Oban boots (config present). Use a dedicated Redis DB index for test to avoid cross-talk (e.g. `redis://redis:6379/1` in test).
- [ ] Gate + commit: `feat(infra): redis, oban, finch, argon2 wiring`.

## Task 2.2 — SDK key generation + hashing + verification
**Files:** `lib/flare/projects.ex` (extend), `test/flare/sdk_key_test.exs`.

- [ ] `Projects.generate_sdk_key(environment, kind)` → generates a random secret, splits into a public `prefix` (e.g. `"sdk_" <> 8 url-safe chars`) + secret remainder; stores `Argon2.hash_pwd_salt(secret)` in `hashed_secret`; returns `{:ok, %{sdk_key: %SdkKey{}, plaintext: full_token}}` where `full_token = prefix <> "." <> secret` shown ONCE.
- [ ] `Projects.verify_sdk_key(token)` → split on `.`; look up by `prefix`; `Argon2.verify_pass(secret, hashed_secret)`; check not expired; on success touch `last_used_at` (async/cheap) and return `{:ok, %SdkKey{}}`; else `{:error, :invalid}`. Constant-time: call `Argon2.no_user_verify()` when prefix not found to avoid timing oracle.
- [ ] Same shape for `generate_api_key/2` + `verify_api_key/1` (org-scoped, carries `permissions`).
- [ ] Tests: round-trip verify; wrong secret → error; unknown prefix → error (and no crash); expired → error.
- [ ] Gate + commit: `feat(projects): SDK/API key generation, hashing, verification`.

## Task 2.3 — Ruleset payload builder + Redis cache
**Files:** `lib/flare/flags.ex` (add `ruleset_payload/1`), `lib/flare/sync/ruleset_cache.ex`, `lib/flare/evaluation/ruleset.ex` (accept string keys), `test/flare/sync/ruleset_cache_test.exs`.

- [ ] `Flags.ruleset_payload(env)` → `%{"version" => v, "flags" => [flag_maps], "segments" => seg_map}` — JSON-serializable, string keys, RAW rules (not inlined). Reuses the same query as `build_ruleset` but emits maps instead of a compiled struct. Add `client_available` filtering: add a migration `feature_flags.client_available :boolean default true`; when building for a `client`/`mobile` key, drop flags where `client_available == false`. Signature: `ruleset_payload(env, key_kind \\ :server)`.
- [ ] `Ruleset.build/3` + `Flags.to_flag_map` must accept string-keyed flag maps (from JSON). Make `build/3` normalize: read `f["key"] || f.key` etc., OR add `Ruleset.from_payload(payload)` that maps string-keyed flag maps → the atom-keyed shape `build/3` expects, then calls `build/3`. Prefer `Ruleset.from_payload/1` so `build/3` stays as-is. `from_payload` also passes `segments` through to inlining.
- [ ] `Flare.Sync.RulesetCache` — `get(env_id)` returns cached JSON string from Redis key `flare:ruleset:{env_id}` (or rebuilds+caches on miss); `put(env, key_kind)` builds payload, `Jason.encode!`, writes Redis with the version; `version(env_id)` reads a cheap `flare:ruleset_version:{env_id}` counter. Cache both server and client variants under distinct keys (`:server`/`:client`).
- [ ] Tests: build → cache → `get` returns identical decoded payload; `from_payload` → `Ruleset.build` → evaluate matches DB-built ruleset; client key excludes a `client_available: false` flag.
- [ ] Gate + commit: `feat(sync): ruleset payload builder + Redis cache + client-key filtering`.

## Task 2.4 — Version bump + broadcast on flag change
**Files:** `lib/flare/flags.ex` (wrap mutations), `lib/flare/audit.ex` + `lib/flare/audit/log_worker.ex` (Oban), `test/flare/flags_broadcast_test.exs`.

- [ ] `Flags.update_env_setting_and_publish(flag, env, attrs, actor)` in ONE `Repo.transaction`: update `flag_environment_settings` → `Environment` bump `ruleset_version` (via `update_all inc: [ruleset_version: 1]`, re-read new value) → insert `flag_versions` row (snapshot = `ruleset_payload` for that flag, `change_type`) → enqueue `Flare.Audit.LogWorker` (Oban) with before/after. After commit: `RulesetCache.put(env, :server)` + `:client`, then `Phoenix.PubSub.broadcast(Flare.PubSub, "env:#{env.id}", {:ruleset_updated, new_version})`.
- [ ] `Flare.Audit.log_async(attrs)` enqueues an Oban job that inserts an `AuditLog`. `LogWorker` performs the insert.
- [ ] Tests: calling the publish fn increments `ruleset_version`, writes exactly one `flag_versions` row with the new version, enqueues one audit job (assert via `Oban.Testing`), and broadcasts once (subscribe in test, assert_receive `{:ruleset_updated, v}`).
- [ ] Gate + commit: `feat(sync): transactional version bump + audit + PubSub broadcast on flag change`.

## Task 2.5 — Sync.ConnectionRegistry (port beacon)
**Files:** `lib/flare/sync/connection_registry.ex`, `test/flare/sync/connection_registry_test.exs`.

- [ ] ETS bag `:flare_sdk_connections`, key `(sdk_key_id, conn_id)` → pid + `System.monotonic_time`. API: `register/3`, `unregister/2`, `lookup(sdk_key_id)`, `count/0`, `count_for(sdk_key_id)`, `evict_oldest(sdk_key_id)` (sends `:conn_evicted`, returns `{:ok,pid}|:none`). Mirror beacon's `connection_registry.ex` (note the 3-tuple wildcard match gotcha). GenServer owns the table.
- [ ] Add to supervision tree.
- [ ] Tests mirror beacon's: register/lookup/unregister/count/evict-oldest ordering.
- [ ] Gate + commit: `feat(sync): SDK connection registry (ETS, per-key cap, evict-oldest)`.

## Task 2.6 — Sync.SSEHandler (port beacon, simplified)
**Files:** `lib/flare/sync/sse_handler.ex`, `test/flare/sync/sse_handler_test.exs`.

- [ ] Per-connection GenServer (`restart: :temporary`). State: `conn_owner` (controller pid), `sdk_key_id`, `conn_id`, `env_id`, `last_version`. On init: `Process.monitor(conn_owner)`, `PubSub.subscribe("env:#{env_id}")`, `ConnectionRegistry.register`, schedule heartbeat (~25s). NO datastore I/O.
- [ ] `handle_info({:ruleset_updated, v}, state)`: mailbox backpressure check (`message_queue_len > @max`, if exceeded send `{:sse_close, :overloaded}` + stop); else send `{:sse_chunk, sse_event("put", payload_ref, v)}` to `conn_owner`. To keep the handler I/O-free, it sends only the version + a signal; the controller fetches the payload from `RulesetCache` and writes it. (Decision: handler sends `{:ruleset_updated, v}` to owner; owner does cache read + chunk write. This preserves "handler does no I/O".)
- [ ] Heartbeat: send `{:sse_chunk, ":\n\n"}` (SSE comment) to owner; reschedule. `:conn_evicted` → `{:sse_close, :evicted}` + stop. `{:DOWN, conn_owner}` → stop. `terminate` → unregister.
- [ ] Tests: subscribe→broadcast→owner receives `{:ruleset_updated, v}`; overloaded mailbox → `{:sse_close, :overloaded}`; evicted → close; heartbeat fires (short interval via config).
- [ ] Gate + commit: `feat(sync): per-connection SSE handler (beacon pattern, no I/O, backpressure)`.

## Task 2.7 — SDK controllers: stream (SSE) + ruleset (REST + polling 304)
**Files:** `lib/flare_web/controllers/sdk_controller.ex`, `lib/flare_web/plugs/sdk_auth.ex`, router, `test/flare_web/sdk_controller_test.exs`.

- [ ] `SdkAuth` plug: read `Authorization: Bearer <token>` (or `?sdk_key=` for browser); `Projects.verify_sdk_key`; assign `:sdk_key`, `:environment`, `:key_kind`; 401 on failure.
- [ ] `GET /sdk/ruleset` → `RulesetCache.get(env_id, key_kind)`; support `?version=N` → if `== current` return `304`, else `200` JSON. `ETag` header = version.
- [ ] `GET /sdk/stream` → SSE via Bandit chunked response: set headers (`text/event-stream`, `cache-control: no-cache`, `connection: keep-alive`), read `Last-Event-ID` (= client version); if `env.ruleset_version > client_version`, immediately write the current payload as a `put` event; start an `SSEHandler` (link owner = the request process); loop receiving `{:sse_chunk, data}` → `chunk(conn, data)`, `{:ruleset_updated, v}` → fetch cache + write `put`, `{:sse_close, reason}` → halt. Handle client disconnect (`{:plug_conn, :sent}` / send failure) → stop handler.
- [ ] Tests: authless → 401; `GET /sdk/ruleset` 200 body has version+flags; `?version=current` → 304; SSE connect with stale `Last-Event-ID` → receives an immediate `put` with current version (use a streaming test client or assert the first chunk).
- [ ] Gate + commit: `feat(api): SDK ruleset endpoint (304 polling) + SSE stream with replay`.

## Task 2.8 — REST management API (+ API-key auth, scoped)
**Files:** `lib/flare_web/controllers/api/*`, `lib/flare_web/plugs/api_auth.ex`, router `/api` scope, tests.

- [ ] `ApiAuth` plug: verify API key, assign org + permissions (permission enforcement is shallow here — org-scoped only; deep RBAC is Increment 4).
- [ ] JSON CRUD for projects, environments, flags (create/list/update/archive), segments, and `POST /api/.../flags/:id/environments/:env/settings` which calls `Flags.update_env_setting_and_publish` (so REST changes also broadcast). Key management endpoints (`POST /sdk-keys`, `POST /api-keys`, rotate stubs).
- [ ] Tests: create flag via API → appears in `/sdk/ruleset`; changing a setting via API broadcasts + bumps version.
- [ ] Gate + commit: `feat(api): REST management API (api-key auth, CRUD, publish on change)`.

## Task 2.9 — Rate limiting plug
**Files:** `lib/flare_web/plugs/rate_limit.ex`, test.

- [ ] Redis token-bucket keyed by key id (`flare:rl:{key_id}`), configurable limit/window; on exceed → 429 with `Retry-After`. Apply to `/sdk/*` and `/api/*`.
- [ ] Tests: under limit ok; over limit → 429.
- [ ] Gate + commit: `feat(api): Redis token-bucket rate limiting`.

## Task 2.10 — Reference Elixir SDK
**Files:** `sdks/elixir/` (a mix lib `flare_sdk`) OR `lib/flare/sdk.ex` in-repo. DECISION: in-repo module `Flare.SDK` for Increment 2 (extract to standalone package in Increment 5); it can call `Flare.Evaluation` directly. Tests `test/flare/sdk_test.exs`.

- [ ] `Flare.SDK.Client` GenServer: `start_link(base_url:, sdk_key:, mode: :streaming|:polling|:offline, bootstrap: payload \\ nil)`. On init: bootstrap (from passed payload or `GET /sdk/ruleset` via Finch) → build `Ruleset` via `Ruleset.from_payload` → cache in state. Streaming: open SSE via Finch stream, on `put` update cache + version, auto-reconnect with `Last-Event-ID`. Polling: `refresh/1` every interval via `?version=`. Offline: evaluate from bootstrap only.
- [ ] Public API: `is_enabled(client, flag, ctx)`, `variation(client, flag, ctx)`, `json(client, flag, ctx)`, `identify(client, ctx)` (store default ctx), `refresh(client)`, `subscribe(client, pid)` (send change msgs), `offline_mode(client)`, `bootstrap(client, payload)`. All evaluations LOCAL via `Flare.Evaluation.evaluate/3` — zero network per eval.
- [ ] Tests: bootstrap from payload → evaluate offline; `variation` matches server; `identify` changes result; polling `refresh` picks up a change.
- [ ] Gate + commit: `feat(sdk): reference Elixir SDK (local eval, bootstrap/stream/poll/offline)`.

## Task 2.11 — End-to-end integration test (acceptance gate)
**Files:** `test/flare/e2e_sync_test.exs`.

- [ ] Start the endpoint (ConnCase / a real Bandit port for SSE), create org/project/env/flag + SDK key, start a `Flare.SDK.Client` in `:streaming` mode pointed at the test server. Assert initial `variation` = default. Then `Flags.update_env_setting_and_publish` to flip the flag. Assert the SDK's local `variation` reflects the change within a timeout (via `subscribe` message or polling the client). Also test `:polling` mode picks up the change on `refresh`.
- [ ] This is the increment's acceptance test — flag change → PubSub → SSE → SDK cache → local eval, end to end.
- [ ] Gate + commit: `test(e2e): flag change reaches connected SDK end-to-end`.

## Task 2.12 — Increment-2 quality gate
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix test` all clean. Fix issues. Commit.

---

## Decisions & scope notes
- **Handler does no I/O:** SSEHandler forwards `{:ruleset_updated, v}`; the controller process (which owns the socket) reads `RulesetCache` and writes the chunk. Preserves beacon's "handler has no datastore calls" invariant.
- **Client-key filtering:** added minimally via `feature_flags.client_available`; deep client/mobile data-scoping tests are Increment 4.
- **RBAC:** shallow (org-scoped) here; deep scope enforcement + isolation tests are Increment 4.
- **Elixir SDK lives in-repo** this increment (calls `Flare.Evaluation` directly); extracted to a standalone package in Increment 5 alongside the other SDKs.
- **Deferred within sync:** Last-Event-ID delta replay optimization (we send a full payload on reconnect if behind — correct, just not delta-optimized); multi-node PubSub adapter (PG2 default is fine for now); load test to Increment 6.

## Self-review vs roadmap
Covers roadmap Increment 2 tasks 1–12: infra (2.1), key hashing (2.2), cache+serialization+client-filter (2.3), version bump+broadcast (2.4), ConnectionRegistry (2.5), SSEHandler (2.6), SSE controller+replay+polling (2.7), REST API (2.8), rate limiting (2.9), Elixir SDK (2.10), e2e (2.11), quality gate (2.12). No placeholders. Wire contract pinned. Beacon reuse explicit.
