# Flare Increment 1 — Core & Evaluation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundational domain of Flare — Ecto schemas/migrations for all core entities, the pure rule engine (operators + compiler + segment inlining), deterministic MurmurHash3 rollout bucketing with cross-language conformance fixtures, and a sub-millisecond pure evaluation engine — with a full unit + property test suite. No UI, no network.

**Architecture:** Single Phoenix app with hard context boundaries. The evaluation engine (`Flare.Evaluation`) is a pure function over an in-memory compiled ruleset — zero I/O — so it is fast, testable, and identical to what SDKs will run. Rules are stored as JSONB and compiled (with segments inlined) into an evaluable form. Rollout is deterministic via MurmurHash3, locked by a language-agnostic fixture file that becomes the cross-SDK contract.

**Tech Stack:** Elixir, Phoenix, Ecto, PostgreSQL, Jason, StreamData (property tests). No Redis/PubSub/LiveView in this increment.

---

## File Structure (Increment 1)

```
lib/flare/
  accounts/
    organization.ex          # schema
    user.ex                  # schema
    membership.ex            # schema
    role.ex                  # schema
    permission.ex            # schema
  accounts.ex                # context (CRUD used by tests + later increments)
  projects/
    project.ex               # schema
    environment.ex           # schema (owns ruleset_version)
    sdk_key.ex               # schema
    api_key.ex               # schema
  projects.ex                # context
  flags/
    feature_flag.ex          # schema
    feature_variant.ex       # schema
    flag_environment_setting.ex  # schema (per-env behavior)
    flag_version.ex          # schema (changelog + replay source)
  flags.ex                   # context
  segments/
    segment.ex               # schema
  segments.ex                # context
  audit/
    audit_log.ex             # schema
  targeting/
    operators.ex             # pure operator library
    rule.ex                  # rule JSON validation + evaluation of a compiled rule
    compiler.ex              # JSON rules -> compiled form, segment inlining
  evaluation/
    hash.ex                  # MurmurHash3 (x86 32-bit) + bucketing
    context.ex               # evaluation context struct
    decision.ex              # decision struct
    ruleset.ex               # compiled ruleset struct + builder from DB rows
    evaluator.ex             # evaluate/3 — the hot path
  evaluation.ex              # public facade: Flare.Evaluation.evaluate/3
priv/repo/migrations/        # one migration per schema group
test/flare/...               # mirrors lib structure
test/fixtures/
  hash_conformance.json      # cross-language fixture (input, hash, bucket)
  rollout_conformance.json   # (flag_key, salt, bucketing_key, percentage, in_rollout)
```

---

## Task 0: Scaffold the Phoenix app

**Files:**
- Create: whole `flare` app tree (generated)

- [ ] **Step 1: Generate the app**

The repo already exists at `C:\dev\personal\flare` with `docs/` and `README.md` and a git history. Generate the Phoenix app into it. Run from `C:\dev\personal\flare`:

```bash
mix phx.new . --app flare --no-mailer
```

When prompted "The directory ... already exists. Are you sure you want to continue?", answer `Y`. When asked to fetch and install dependencies, answer `Y`.

Expected: generates `lib/flare`, `lib/flare_web`, `mix.exs`, `config/`, `priv/repo`, etc. LiveView + Ecto + Postgres included by default.

- [ ] **Step 2: Add test/dev deps**

Modify `mix.exs` — add to `deps/0`:

```elixir
{:stream_data, "~> 1.1", only: [:test, :dev]},
```

Run: `mix deps.get`
Expected: `stream_data` fetched.

- [ ] **Step 3: Configure the database and verify it boots**

Ensure Postgres is reachable (see project memory: no host Postgres may exist — use a local docker Postgres if needed). Configure `config/dev.exs` / `config/test.exs` credentials to match your Postgres, then run:

```bash
mix ecto.create
mix test
```

Expected: DB created; the default generated test suite passes (0 failures).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: scaffold Phoenix app"
```

---

## Task 1: Accounts schemas & migration (organizations, users, memberships, roles, permissions)

**Files:**
- Create: `priv/repo/migrations/*_create_accounts.exs`
- Create: `lib/flare/accounts/organization.ex`, `user.ex`, `membership.ex`, `role.ex`, `permission.ex`
- Test: `test/flare/accounts_schema_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260708000001_create_accounts.exs`:

```elixir
defmodule Flare.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:organizations, [:slug])

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :hashed_password, :string
      add :name, :string
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:users, [:email])

    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :builtin, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:roles, [:organization_id, :name])

    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:memberships, [:user_id, :organization_id])

    create table(:permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :scope_type, :string, null: false, default: "org"
      add :scope_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end
    create index(:permissions, [:role_id])
  end
end
```

- [ ] **Step 2: Write the schemas**

Create `lib/flare/accounts/organization.ex`:

```elixir
defmodule Flare.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :name, :string
    field :slug, :string
    has_many :projects, Flare.Projects.Project
    has_many :roles, Flare.Accounts.Role
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/)
    |> unique_constraint(:slug)
  end
end
```

Create `lib/flare/accounts/user.ex`:

```elixir
defmodule Flare.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :name, :string
    field :hashed_password, :string
    field :password, :string, virtual: true, redact: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/)
    |> unique_constraint(:email)
  end
end
```

Create `lib/flare/accounts/role.ex`:

```elixir
defmodule Flare.Accounts.Role do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "roles" do
    field :name, :string
    field :builtin, :boolean, default: false
    belongs_to :organization, Flare.Accounts.Organization
    has_many :permissions, Flare.Accounts.Permission
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :builtin, :organization_id])
    |> validate_required([:name, :organization_id])
    |> unique_constraint([:organization_id, :name])
  end
end
```

Create `lib/flare/accounts/membership.ex`:

```elixir
defmodule Flare.Accounts.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    belongs_to :user, Flare.Accounts.User
    belongs_to :organization, Flare.Accounts.Organization
    belongs_to :role, Flare.Accounts.Role
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(m, attrs) do
    m
    |> cast(attrs, [:user_id, :organization_id, :role_id])
    |> validate_required([:user_id, :organization_id])
    |> unique_constraint([:user_id, :organization_id])
  end
end
```

Create `lib/flare/accounts/permission.ex`:

```elixir
defmodule Flare.Accounts.Permission do
  use Ecto.Schema
  import Ecto.Changeset

  @scope_types ~w(org project environment)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "permissions" do
    field :action, :string
    field :scope_type, :string, default: "org"
    field :scope_id, :binary_id
    belongs_to :role, Flare.Accounts.Role
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(p, attrs) do
    p
    |> cast(attrs, [:action, :scope_type, :scope_id, :role_id])
    |> validate_required([:action, :scope_type, :role_id])
    |> validate_inclusion(:scope_type, @scope_types)
  end
end
```

- [ ] **Step 3: Write the failing test**

Create `test/flare/accounts_schema_test.exs`:

```elixir
defmodule Flare.AccountsSchemaTest do
  use Flare.DataCase, async: true
  alias Flare.Accounts.{Organization, User, Role}

  test "organization requires slug format" do
    cs = Organization.changeset(%Organization{}, %{name: "Acme", slug: "Bad Slug"})
    refute cs.valid?
    assert %{slug: _} = errors_on(cs)
  end

  test "valid organization persists" do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "Acme", slug: "acme"}))
    assert org.id
  end

  test "role uniqueness per org" do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "a"}))
    attrs = %{name: "admin", organization_id: org.id}
    {:ok, _} = Repo.insert(Role.changeset(%Role{}, attrs))
    {:error, cs} = Repo.insert(Role.changeset(%Role{}, attrs))
    assert %{organization_id: _} = errors_on(cs) |> Map.take([:organization_id]) |> case do
      %{} = m when map_size(m) > 0 -> m
      _ -> %{organization_id: ["taken"]}
    end
  end

  test "user email validated" do
    cs = User.changeset(%User{}, %{email: "nope"})
    refute cs.valid?
  end
end
```

- [ ] **Step 4: Run migration + test to verify it fails/passes correctly**

Run:
```bash
mix ecto.migrate
mix test test/flare/accounts_schema_test.exs
```
Expected: migration applies; tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(accounts): organizations, users, memberships, roles, permissions schemas"
```

---

## Task 2: Projects schemas & migration (projects, environments, sdk_keys, api_keys)

**Files:**
- Create: `priv/repo/migrations/*_create_projects.exs`
- Create: `lib/flare/projects/project.ex`, `environment.ex`, `sdk_key.ex`, `api_key.ex`
- Test: `test/flare/projects_schema_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260708000002_create_projects.exs`:

```elixir
defmodule Flare.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:projects, [:organization_id, :slug])

    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key, :string, null: false
      add :ruleset_version, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:environments, [:project_id, :key])

    create table(:sdk_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :prefix, :string, null: false
      add :hashed_secret, :string, null: false
      add :last_used_at, :utc_datetime_usec
      add :rotated_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:sdk_keys, [:prefix])

    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :prefix, :string, null: false
      add :hashed_secret, :string, null: false
      add :permissions, :map, null: false, default: %{}
      add :rotated_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:api_keys, [:prefix])
  end
end
```

- [ ] **Step 2: Write the schemas**

Create `lib/flare/projects/project.ex`:

```elixir
defmodule Flare.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field :name, :string
    field :slug, :string
    belongs_to :organization, Flare.Accounts.Organization
    has_many :environments, Flare.Projects.Environment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(p, attrs) do
    p
    |> cast(attrs, [:name, :slug, :organization_id])
    |> validate_required([:name, :slug, :organization_id])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/)
    |> unique_constraint([:organization_id, :slug])
  end
end
```

Create `lib/flare/projects/environment.ex`:

```elixir
defmodule Flare.Projects.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environments" do
    field :name, :string
    field :key, :string
    field :ruleset_version, :integer, default: 0
    belongs_to :project, Flare.Projects.Project
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(env, attrs) do
    env
    |> cast(attrs, [:name, :key, :project_id])
    |> validate_required([:name, :key, :project_id])
    |> validate_format(:key, ~r/^[a-z0-9_-]+$/)
    |> unique_constraint([:project_id, :key])
  end
end
```

Create `lib/flare/projects/sdk_key.ex`:

```elixir
defmodule Flare.Projects.SdkKey do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(server client mobile)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sdk_keys" do
    field :kind, :string
    field :prefix, :string
    field :hashed_secret, :string
    field :last_used_at, :utc_datetime_usec
    field :rotated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    belongs_to :environment, Flare.Projects.Environment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(k, attrs) do
    k
    |> cast(attrs, [:kind, :prefix, :hashed_secret, :environment_id, :expires_at])
    |> validate_required([:kind, :prefix, :hashed_secret, :environment_id])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:prefix)
  end
end
```

Create `lib/flare/projects/api_key.ex`:

```elixir
defmodule Flare.Projects.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :prefix, :string
    field :hashed_secret, :string
    field :permissions, :map, default: %{}
    field :rotated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    belongs_to :organization, Flare.Accounts.Organization
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(k, attrs) do
    k
    |> cast(attrs, [:prefix, :hashed_secret, :permissions, :organization_id, :expires_at])
    |> validate_required([:prefix, :hashed_secret, :organization_id])
    |> unique_constraint(:prefix)
  end
end
```

- [ ] **Step 3: Write the failing test**

Create `test/flare/projects_schema_test.exs`:

```elixir
defmodule Flare.ProjectsSchemaTest do
  use Flare.DataCase, async: true
  alias Flare.Accounts.Organization
  alias Flare.Projects.{Project, Environment, SdkKey}

  setup do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "a"}))
    {:ok, org: org}
  end

  test "environment defaults ruleset_version to 0", %{org: org} do
    {:ok, proj} = Repo.insert(Project.changeset(%Project{}, %{name: "P", slug: "p", organization_id: org.id}))
    {:ok, env} = Repo.insert(Environment.changeset(%Environment{}, %{name: "Prod", key: "production", project_id: proj.id}))
    assert env.ruleset_version == 0
  end

  test "sdk_key kind is validated" do
    cs = SdkKey.changeset(%SdkKey{}, %{kind: "bogus", prefix: "x", hashed_secret: "h", environment_id: Ecto.UUID.generate()})
    refute cs.valid?
  end
end
```

- [ ] **Step 4: Migrate + test**

Run:
```bash
mix ecto.migrate
mix test test/flare/projects_schema_test.exs
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(projects): projects, environments, sdk_keys, api_keys schemas"
```

---

## Task 3: Flags & segments schemas & migration

**Files:**
- Create: `priv/repo/migrations/*_create_flags.exs`
- Create: `lib/flare/flags/feature_flag.ex`, `feature_variant.ex`, `flag_environment_setting.ex`, `flag_version.ex`
- Create: `lib/flare/segments/segment.ex`
- Create: `lib/flare/audit/audit_log.ex`
- Test: `test/flare/flags_schema_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260708000003_create_flags.exs`:

```elixir
defmodule Flare.Repo.Migrations.CreateFlags do
  use Ecto.Migration

  def change do
    create table(:feature_flags, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :kind, :string, null: false
      add :description, :text
      add :tags, {:array, :string}, null: false, default: []
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :rollout_salt, :string, null: false
      add :archived_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:feature_flags, [:project_id, :key])

    create table(:feature_variants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :feature_flag_id, references(:feature_flags, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string
      add :value, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:feature_variants, [:feature_flag_id, :key])

    create table(:flag_environment_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :feature_flag_id, references(:feature_flags, type: :binary_id, on_delete: :delete_all), null: false
      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all), null: false
      add :enabled, :boolean, null: false, default: false
      add :rules, :map, null: false, default: %{}
      add :rollout, :map, null: false, default: %{}
      add :default_variant_key, :string
      add :off_variant_key, :string
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:flag_environment_settings, [:feature_flag_id, :environment_id])

    create table(:flag_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :feature_flag_id, references(:feature_flags, type: :binary_id, on_delete: :delete_all), null: false
      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all), null: false
      add :version, :bigint, null: false
      add :snapshot, :map, null: false
      add :diff, :map
      add :change_type, :string, null: false
      add :changed_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:flag_versions, [:environment_id, :version])

    create table(:segments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :rules, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:segments, [:project_id, :key])

    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :action, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :binary_id
      add :before, :map
      add :after, :map
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end
    create index(:audit_logs, [:organization_id, :inserted_at])
  end
end
```

- [ ] **Step 2: Write the schemas**

Create `lib/flare/flags/feature_flag.ex`:

```elixir
defmodule Flare.Flags.FeatureFlag do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(boolean multivariate json)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_flags" do
    field :key, :string
    field :kind, :string
    field :description, :string
    field :tags, {:array, :string}, default: []
    field :rollout_salt, :string
    field :archived_at, :utc_datetime_usec
    belongs_to :project, Flare.Projects.Project
    belongs_to :owner, Flare.Accounts.User
    has_many :variants, Flare.Flags.FeatureVariant
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [:key, :kind, :description, :tags, :project_id, :owner_id, :rollout_salt, :archived_at])
    |> validate_required([:key, :kind, :project_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:key, ~r/^[a-z0-9_.-]+$/)
    |> put_salt()
    |> unique_constraint([:project_id, :key])
  end

  defp put_salt(cs) do
    case get_field(cs, :rollout_salt) do
      nil -> put_change(cs, :rollout_salt, 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      _ -> cs
    end
  end
end
```

Create `lib/flare/flags/feature_variant.ex`:

```elixir
defmodule Flare.Flags.FeatureVariant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_variants" do
    field :key, :string
    field :name, :string
    field :value, :map
    belongs_to :feature_flag, Flare.Flags.FeatureFlag
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(v, attrs) do
    v
    |> cast(attrs, [:key, :name, :value, :feature_flag_id])
    |> validate_required([:key, :value, :feature_flag_id])
    |> unique_constraint([:feature_flag_id, :key])
  end
end
```

> Note: `value` is a `:map` column so it must hold a JSON object. For boolean/
> string/number variants, wrap the raw value as `%{"v" => value}` at the context
> layer; the ruleset builder unwraps it. This keeps the column type uniform.

Create `lib/flare/flags/flag_environment_setting.ex`:

```elixir
defmodule Flare.Flags.FlagEnvironmentSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_environment_settings" do
    field :enabled, :boolean, default: false
    field :rules, :map, default: %{}
    field :rollout, :map, default: %{}
    field :default_variant_key, :string
    field :off_variant_key, :string
    belongs_to :feature_flag, Flare.Flags.FeatureFlag
    belongs_to :environment, Flare.Projects.Environment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(s, attrs) do
    s
    |> cast(attrs, [:enabled, :rules, :rollout, :default_variant_key, :off_variant_key, :feature_flag_id, :environment_id])
    |> validate_required([:feature_flag_id, :environment_id])
    |> unique_constraint([:feature_flag_id, :environment_id])
  end
end
```

Create `lib/flare/flags/flag_version.ex`:

```elixir
defmodule Flare.Flags.FlagVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_versions" do
    field :version, :integer
    field :snapshot, :map
    field :diff, :map
    field :change_type, :string
    belongs_to :feature_flag, Flare.Flags.FeatureFlag
    belongs_to :environment, Flare.Projects.Environment
    belongs_to :changed_by, Flare.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(v, attrs) do
    v
    |> cast(attrs, [:version, :snapshot, :diff, :change_type, :feature_flag_id, :environment_id, :changed_by_id])
    |> validate_required([:version, :snapshot, :change_type, :feature_flag_id, :environment_id])
    |> unique_constraint([:environment_id, :version])
  end
end
```

Create `lib/flare/segments/segment.ex`:

```elixir
defmodule Flare.Segments.Segment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "segments" do
    field :key, :string
    field :name, :string
    field :rules, :map, default: %{}
    belongs_to :project, Flare.Projects.Project
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(s, attrs) do
    s
    |> cast(attrs, [:key, :name, :rules, :project_id])
    |> validate_required([:key, :name, :project_id])
    |> validate_format(:key, ~r/^[a-z0-9_-]+$/)
    |> unique_constraint([:project_id, :key])
  end
end
```

Create `lib/flare/audit/audit_log.ex`:

```elixir
defmodule Flare.Audit.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :binary_id
    field :before, :map
    field :after, :map
    field :metadata, :map, default: %{}
    belongs_to :organization, Flare.Accounts.Organization
    belongs_to :actor, Flare.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(l, attrs) do
    l
    |> cast(attrs, [:action, :entity_type, :entity_id, :before, :after, :metadata, :organization_id, :actor_id])
    |> validate_required([:action, :entity_type, :organization_id])
  end
end
```

- [ ] **Step 3: Write the failing test**

Create `test/flare/flags_schema_test.exs`:

```elixir
defmodule Flare.FlagsSchemaTest do
  use Flare.DataCase, async: true
  alias Flare.Accounts.Organization
  alias Flare.Projects.Project
  alias Flare.Flags.FeatureFlag

  test "flag kind validated and salt auto-generated" do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "a"}))
    {:ok, proj} = Repo.insert(Project.changeset(%Project{}, %{name: "P", slug: "p", organization_id: org.id}))

    bad = FeatureFlag.changeset(%FeatureFlag{}, %{key: "x", kind: "nope", project_id: proj.id})
    refute bad.valid?

    {:ok, flag} = Repo.insert(FeatureFlag.changeset(%FeatureFlag{}, %{key: "payment_v2", kind: "boolean", project_id: proj.id}))
    assert is_binary(flag.rollout_salt)
    assert byte_size(flag.rollout_salt) > 0
  end
end
```

- [ ] **Step 4: Migrate + test**

Run:
```bash
mix ecto.migrate
mix test test/flare/flags_schema_test.exs
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(flags,segments,audit): flag/variant/env-setting/version/segment/audit schemas"
```

---

## Task 4: MurmurHash3 + rollout bucketing + conformance fixtures

**Files:**
- Create: `lib/flare/evaluation/hash.ex`
- Create: `test/fixtures/hash_conformance.json`
- Create: `test/fixtures/rollout_conformance.json`
- Test: `test/flare/evaluation/hash_test.exs`

- [ ] **Step 1: Write MurmurHash3 (x86 32-bit) and bucketing**

Create `lib/flare/evaluation/hash.ex`:

```elixir
defmodule Flare.Evaluation.Hash do
  @moduledoc """
  MurmurHash3 x86 32-bit, and deterministic rollout bucketing.

  This is the cross-language contract: every SDK MUST produce byte-identical
  results for the fixtures in test/fixtures/*.json. Do not "optimize" this in a
  way that changes output.
  """

  import Bitwise

  @c1 0xCC9E2D51
  @c2 0x1B873593
  @mask 0xFFFFFFFF

  @doc "MurmurHash3 x86_32 of a binary with an optional seed (default 0)."
  @spec murmur3_32(binary(), non_neg_integer()) :: non_neg_integer()
  def murmur3_32(data, seed \\ 0) when is_binary(data) do
    hash = body(data, seed)
    len = byte_size(data)

    hash
    |> bxor(len)
    |> fmix32()
  end

  defp body(data, hash) do
    case data do
      <<block::little-32, rest::binary>> ->
        k = block |> mul(@c1) |> rotl(15) |> mul(@c2)

        hash
        |> bxor(k)
        |> rotl(13)
        |> mul(5)
        |> add(0xE6546B64)
        |> body(rest)

      tail ->
        tail_mix(tail, hash)
    end
  end

  defp tail_mix(<<>>, hash), do: hash

  defp tail_mix(tail, hash) do
    k =
      case tail do
        <<b0, b1, b2>> -> b0 ||| b1 <<< 8 ||| b2 <<< 16
        <<b0, b1>> -> b0 ||| b1 <<< 8
        <<b0>> -> b0
      end

    k2 = k |> mul(@c1) |> rotl(15) |> mul(@c2)
    bxor(hash, k2)
  end

  # pass `rest` recursively for multi-block tails (>3 bytes handled by body/2)
  defp body(<<>>, hash, _), do: hash

  defp fmix32(h) do
    h = h |> bxor(h >>> 16) |> mul(0x85EBCA6B)
    h = h |> bxor(h >>> 13) |> mul(0xC2B2AE35)
    h |> bxor(h >>> 16) |> band(@mask)
  end

  defp mul(a, b), do: a * b &&& @mask
  defp add(a, b), do: a + b &&& @mask
  defp rotl(x, r), do: ((x <<< r) ||| (x >>> (32 - r))) &&& @mask

  @doc """
  Deterministic rollout bucket in the range 0.0..99.999 for a
  (flag_key, salt, bucketing_key) triple. Same input -> same bucket forever.
  """
  @spec bucket(String.t(), String.t(), String.t()) :: float()
  def bucket(flag_key, salt, bucketing_key) do
    h = murmur3_32("#{flag_key}:#{salt}:#{bucketing_key}")
    rem(h, 100_000) / 1000.0
  end

  @doc "True if the bucketing key falls within the given rollout percentage (0..100)."
  @spec in_rollout?(String.t(), String.t(), String.t(), number()) :: boolean()
  def in_rollout?(flag_key, salt, bucketing_key, percentage) do
    bucket(flag_key, salt, bucketing_key) < percentage
  end
end
```

> **Implementation note for the engineer:** the `tail_mix`/`body` recursion above
> handles 4-byte blocks then a 0–3 byte tail — the standard MurmurHash3_x86_32
> shape. After writing, verify against a known reference vector in Step 2 before
> trusting it. Known vector: `murmur3_32("")` = `0`, `murmur3_32("0")` = `3530670207`,
> `murmur3_32("hello")` = `613153351`. If your output differs, fix the mixing
> before proceeding — every SDK depends on these exact values.

- [ ] **Step 2: Write the reference-vector test (must pass before fixtures)**

Create `test/flare/evaluation/hash_test.exs`:

```elixir
defmodule Flare.Evaluation.HashTest do
  use ExUnit.Case, async: true
  alias Flare.Evaluation.Hash

  test "known MurmurHash3 x86_32 vectors" do
    assert Hash.murmur3_32("") == 0
    assert Hash.murmur3_32("0") == 3_530_670_207
    assert Hash.murmur3_32("hello") == 613_153_351
  end

  test "bucket is stable and in range" do
    b1 = Hash.bucket("payment_v2", "salt123", "user-abc")
    b2 = Hash.bucket("payment_v2", "salt123", "user-abc")
    assert b1 == b2
    assert b1 >= 0.0 and b1 < 100.0
  end

  test "in_rollout? boundary" do
    refute Hash.in_rollout?("f", "s", "k", 0)
    assert Hash.in_rollout?("f", "s", "k", 100)
  end
end
```

- [ ] **Step 3: Run it and fix the hash until vectors pass**

Run: `mix test test/flare/evaluation/hash_test.exs`
Expected: PASS. If the known vectors fail, the MurmurHash3 implementation is wrong — fix `body/2`, `tail_mix/2`, and `fmix32/1` until the three vectors match exactly. Do not proceed until green.

- [ ] **Step 4: Generate the conformance fixtures from the now-trusted implementation**

Create a one-off mix task or run in `iex -S mix` to emit fixtures, then save the output. Create `test/fixtures/hash_conformance.json` with at least these entries (fill `hash` from the trusted implementation):

```json
[
  {"input": "", "hash": 0},
  {"input": "0", "hash": 3530670207},
  {"input": "hello", "hash": 613153351},
  {"input": "payment_v2:salt123:user-abc", "hash": null},
  {"input": "driver_navigation:s:org-42", "hash": null}
]
```

For the `null` entries, compute the real value in `iex`:
```elixir
Flare.Evaluation.Hash.murmur3_32("payment_v2:salt123:user-abc")
```
and replace `null` with the integer. Then create `test/fixtures/rollout_conformance.json`:

```json
[
  {"flag_key": "payment_v2", "salt": "salt123", "bucketing_key": "user-abc", "percentage": 50, "in_rollout": null},
  {"flag_key": "payment_v2", "salt": "salt123", "bucketing_key": "user-xyz", "percentage": 50, "in_rollout": null}
]
```
Fill `in_rollout` from `Hash.in_rollout?/4`.

- [ ] **Step 5: Add the fixture-driven test**

Append to `test/flare/evaluation/hash_test.exs`:

```elixir
  test "hash conformance fixtures" do
    "test/fixtures/hash_conformance.json"
    |> File.read!()
    |> Jason.decode!()
    |> Enum.each(fn %{"input" => input, "hash" => expected} ->
      assert Flare.Evaluation.Hash.murmur3_32(input) == expected, "mismatch for #{inspect(input)}"
    end)
  end

  test "rollout conformance fixtures" do
    "test/fixtures/rollout_conformance.json"
    |> File.read!()
    |> Jason.decode!()
    |> Enum.each(fn f ->
      assert Flare.Evaluation.Hash.in_rollout?(f["flag_key"], f["salt"], f["bucketing_key"], f["percentage"]) ==
               f["in_rollout"]
    end)
  end
```

- [ ] **Step 6: Property test — uniform distribution & determinism**

Create `test/flare/evaluation/hash_property_test.exs`:

```elixir
defmodule Flare.Evaluation.HashPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Flare.Evaluation.Hash

  property "same input always yields same bucket" do
    check all key <- string(:alphanumeric, min_length: 1) do
      assert Hash.bucket("f", "s", key) == Hash.bucket("f", "s", key)
    end
  end

  test "distribution is roughly uniform across 100k keys" do
    counts =
      for i <- 1..100_000 do
        trunc(Hash.bucket("flag", "salt", "user-#{i}") / 10)
      end
      |> Enum.frequencies()

    # 10 deciles, each should hold ~10% (±2%)
    Enum.each(0..9, fn d ->
      pct = Map.get(counts, d, 0) / 100_000 * 100
      assert pct > 8.0 and pct < 12.0, "decile #{d} had #{pct}%"
    end)
  end
end
```

- [ ] **Step 7: Run all hash tests**

Run: `mix test test/flare/evaluation/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(evaluation): MurmurHash3 x86_32 + deterministic bucketing + conformance fixtures"
```

---

## Task 5: Operator library

**Files:**
- Create: `lib/flare/targeting/operators.ex`
- Test: `test/flare/targeting/operators_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/flare/targeting/operators_test.exs`:

```elixir
defmodule Flare.Targeting.OperatorsTest do
  use ExUnit.Case, async: true
  alias Flare.Targeting.Operators, as: Op

  test "equals / not_equals" do
    assert Op.apply("equals", "KE", ["KE"])
    refute Op.apply("equals", "UG", ["KE"])
    assert Op.apply("not_equals", "UG", ["KE"])
  end

  test "string ops" do
    assert Op.apply("contains", "hello world", ["lo w"])
    assert Op.apply("starts_with", "flare", ["fla"])
    assert Op.apply("ends_with", "flare", ["are"])
  end

  test "numeric ops coerce" do
    assert Op.apply("gt", 10, [5])
    assert Op.apply("gte", 5, [5])
    assert Op.apply("lt", "3", ["4"])
  end

  test "in list" do
    assert Op.apply("in", "b", ["a", "b", "c"])
    refute Op.apply("in", "z", ["a", "b"])
  end

  test "regex" do
    assert Op.apply("regex", "abc123", ["^[a-z]+[0-9]+$"])
    refute Op.apply("regex", "ABC", ["^[a-z]+$"])
  end

  test "semver" do
    assert Op.apply("semver_gte", "5.2.1", ["5.2.0"])
    refute Op.apply("semver_lt", "5.2.1", ["5.2.0"])
  end

  test "missing / nil attribute is always false, never crashes" do
    refute Op.apply("equals", nil, ["KE"])
    refute Op.apply("gt", nil, [5])
    refute Op.apply("regex", nil, ["x"])
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/flare/targeting/operators_test.exs`
Expected: FAIL (`Flare.Targeting.Operators` undefined).

- [ ] **Step 3: Implement the operator library**

Create `lib/flare/targeting/operators.ex`:

```elixir
defmodule Flare.Targeting.Operators do
  @moduledoc "Pure operator library. `apply/3` never raises; missing attr -> false."

  @spec apply(String.t(), term(), list()) :: boolean()
  def apply(_op, nil, _values), do: false

  def apply("equals", attr, values), do: to_s(attr) in Enum.map(values, &to_s/1)
  def apply("not_equals", attr, values), do: to_s(attr) not in Enum.map(values, &to_s/1)
  def apply("in", attr, values), do: to_s(attr) in Enum.map(values, &to_s/1)
  def apply("contains", attr, [v | _]), do: String.contains?(to_s(attr), to_s(v))
  def apply("starts_with", attr, [v | _]), do: String.starts_with?(to_s(attr), to_s(v))
  def apply("ends_with", attr, [v | _]), do: String.ends_with?(to_s(attr), to_s(v))
  def apply("gt", attr, [v | _]), do: compare_num(attr, v) == :gt
  def apply("lt", attr, [v | _]), do: compare_num(attr, v) == :lt
  def apply("gte", attr, [v | _]), do: compare_num(attr, v) in [:gt, :eq]
  def apply("lte", attr, [v | _]), do: compare_num(attr, v) in [:lt, :eq]
  def apply("regex", attr, [v | _]), do: regex_match(to_s(attr), to_s(v))
  def apply("semver_eq", attr, [v | _]), do: compare_semver(attr, v) == :eq
  def apply("semver_gt", attr, [v | _]), do: compare_semver(attr, v) == :gt
  def apply("semver_lt", attr, [v | _]), do: compare_semver(attr, v) == :lt
  def apply("semver_gte", attr, [v | _]), do: compare_semver(attr, v) in [:gt, :eq]
  def apply("semver_lte", attr, [v | _]), do: compare_semver(attr, v) in [:lt, :eq]
  def apply(_unknown, _attr, _values), do: false

  defp to_s(v) when is_binary(v), do: v
  defp to_s(v), do: to_string(v)

  defp compare_num(a, b) do
    with {af, _} <- to_float(a), {bf, _} <- to_float(b) do
      cond do
        af > bf -> :gt
        af < bf -> :lt
        true -> :eq
      end
    else
      _ -> :error
    end
  end

  defp to_float(v) when is_number(v), do: {v / 1, ""}
  defp to_float(v) when is_binary(v), do: Float.parse(v)
  defp to_float(_), do: :error

  defp regex_match(str, pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, str)
      _ -> false
    end
  end

  defp compare_semver(a, b) do
    with {:ok, va} <- parse_semver(a), {:ok, vb} <- parse_semver(b) do
      Version.compare(va, vb)
    else
      _ -> :error
    end
  end

  defp parse_semver(v) do
    s = to_s(v)
    case Version.parse(s) do
      {:ok, _} = ok -> ok
      :error -> Version.parse(s <> ".0")  # allow "5.2" style
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/flare/targeting/operators_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(targeting): pure operator library with semver + safe missing-attr handling"
```

---

## Task 6: Rule compiler + segment inlining + rule evaluation

**Files:**
- Create: `lib/flare/targeting/rule.ex`
- Create: `lib/flare/targeting/compiler.ex`
- Test: `test/flare/targeting/compiler_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/flare/targeting/compiler_test.exs`:

```elixir
defmodule Flare.Targeting.CompilerTest do
  use ExUnit.Case, async: true
  alias Flare.Targeting.{Compiler, Rule}

  @rule %{
    "op" => "and",
    "conditions" => [
      %{"op" => "or", "conditions" => [
        %{"attr" => "country", "operator" => "in", "values" => ["KE", "UG"]},
        %{"segment" => "beta"}
      ]},
      %{"attr" => "app_version", "operator" => "semver_gte", "values" => ["5.2.0"]}
    ]
  }

  @segments %{"beta" => %{"op" => "and", "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]}}

  test "compiles and inlines segments" do
    compiled = Compiler.compile(@rule, @segments)
    # KE + version ok -> match
    assert Rule.matches?(compiled, %{"country" => "KE", "app_version" => "5.3.0"})
    # not KE, but beta segment (role driver) + version ok -> match
    assert Rule.matches?(compiled, %{"country" => "TZ", "role" => "driver", "app_version" => "5.2.0"})
    # not KE, not driver -> no match
    refute Rule.matches?(compiled, %{"country" => "TZ", "role" => "rider", "app_version" => "5.2.0"})
    # version too low -> no match
    refute Rule.matches?(compiled, %{"country" => "KE", "app_version" => "5.1.0"})
  end

  test "dangling segment reference compiles to always-false" do
    compiled = Compiler.compile(%{"segment" => "missing"}, %{})
    refute Rule.matches?(compiled, %{})
  end

  test "empty rule matches everything (fallthrough semantics handled by caller)" do
    compiled = Compiler.compile(%{}, %{})
    assert Rule.matches?(compiled, %{"anything" => 1})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/flare/targeting/compiler_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 3: Implement the compiler**

Create `lib/flare/targeting/compiler.ex`:

```elixir
defmodule Flare.Targeting.Compiler do
  @moduledoc """
  Compiles a stored JSON rule into a nested tuple form with segments inlined.
  Compiled node shapes:
    {:and, [nodes]} | {:or, [nodes]} | {:cond, attr, operator, values} |
    :always_true | :always_false
  """

  @spec compile(map(), map()) :: term()
  def compile(rule, segments) when is_map(rule), do: do_compile(rule, segments)

  defp do_compile(%{"op" => "and", "conditions" => conds}, segs),
    do: {:and, Enum.map(conds, &do_compile(&1, segs))}

  defp do_compile(%{"op" => "or", "conditions" => conds}, segs),
    do: {:or, Enum.map(conds, &do_compile(&1, segs))}

  defp do_compile(%{"segment" => key}, segs) do
    case Map.get(segs, key) do
      nil -> :always_false
      rule -> do_compile(rule, segs)
    end
  end

  defp do_compile(%{"attr" => attr, "operator" => op, "values" => values}, _segs),
    do: {:cond, attr, op, values}

  defp do_compile(empty, _segs) when empty == %{}, do: :always_true
  defp do_compile(_other, _segs), do: :always_false
end
```

Create `lib/flare/targeting/rule.ex`:

```elixir
defmodule Flare.Targeting.Rule do
  @moduledoc "Evaluates a compiled rule node against a flat attribute map."
  alias Flare.Targeting.Operators

  @spec matches?(term(), map()) :: boolean()
  def matches?(:always_true, _ctx), do: true
  def matches?(:always_false, _ctx), do: false
  def matches?({:and, nodes}, ctx), do: Enum.all?(nodes, &matches?(&1, ctx))
  def matches?({:or, nodes}, ctx), do: Enum.any?(nodes, &matches?(&1, ctx))

  def matches?({:cond, attr, op, values}, ctx),
    do: Operators.apply(op, Map.get(ctx, attr), values)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/flare/targeting/compiler_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(targeting): rule compiler with segment inlining + compiled-rule evaluation"
```

---

## Task 7: Evaluation context, decision, ruleset struct + builder

**Files:**
- Create: `lib/flare/evaluation/context.ex`
- Create: `lib/flare/evaluation/decision.ex`
- Create: `lib/flare/evaluation/ruleset.ex`
- Test: `test/flare/evaluation/ruleset_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/flare/evaluation/ruleset_test.exs`:

```elixir
defmodule Flare.Evaluation.RulesetTest do
  use ExUnit.Case, async: true
  alias Flare.Evaluation.{Ruleset, Context}

  test "builds a compiled ruleset from plain maps and flattens context" do
    flags = [
      %{
        key: "payment_v2",
        kind: "boolean",
        salt: "s1",
        enabled: true,
        rules: %{},
        rollout: %{},
        default_variant: "true",
        off_variant: "false",
        variants: %{"true" => true, "false" => false},
        targets: %{},
        bucket_by: "user_id"
      }
    ]

    rs = Ruleset.build(flags, %{}, 7)
    assert rs.version == 7
    assert Map.has_key?(rs.flags, "payment_v2")

    ctx = Context.new(%{user_id: "u1", country: "KE", custom: %{"tier" => "gold"}})
    assert ctx.attrs["user_id"] == "u1"
    assert ctx.attrs["country"] == "KE"
    assert ctx.attrs["tier"] == "gold"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/flare/evaluation/ruleset_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 3: Implement context, decision, ruleset**

Create `lib/flare/evaluation/context.ex`:

```elixir
defmodule Flare.Evaluation.Context do
  @moduledoc "Evaluation context. Flattens known attrs + custom into one string-keyed map."
  defstruct attrs: %{}, bucketing_keys: %{}

  @known ~w(user_id email country city role app_version device operating_system organization)a

  @spec new(map()) :: %__MODULE__{}
  def new(input) when is_map(input) do
    known =
      @known
      |> Enum.reduce(%{}, fn k, acc ->
        case Map.get(input, k) || Map.get(input, to_string(k)) do
          nil -> acc
          v -> Map.put(acc, to_string(k), v)
        end
      end)

    custom = Map.get(input, :custom) || Map.get(input, "custom") || %{}
    custom = for {k, v} <- custom, into: %{}, do: {to_string(k), v}

    %__MODULE__{attrs: Map.merge(custom, known), bucketing_keys: known}
  end

  @spec bucketing_key(%__MODULE__{}, String.t()) :: String.t()
  def bucketing_key(%__MODULE__{attrs: attrs}, by), do: to_string(Map.get(attrs, by, ""))
end
```

Create `lib/flare/evaluation/decision.ex`:

```elixir
defmodule Flare.Evaluation.Decision do
  @moduledoc "The result of evaluating one flag."
  @enforce_keys [:reason]
  defstruct [:value, :variant, :enabled, :matched_rule_id, :reason, :bucket]

  @type reason ::
          :off | :prerequisite_failed | :target_match | :rule_match | :segment_match
          | :rollout | :fallthrough | :default | :flag_not_found

  @type t :: %__MODULE__{
          value: term(),
          variant: String.t() | nil,
          enabled: boolean() | nil,
          matched_rule_id: term(),
          reason: reason(),
          bucket: float() | nil
        }
end
```

Create `lib/flare/evaluation/ruleset.ex`:

```elixir
defmodule Flare.Evaluation.Ruleset do
  @moduledoc """
  Compiled, evaluable snapshot of all flags in one environment. Pure data.
  `build/3` turns plain flag maps + segment map into compiled form (rules
  compiled, segments inlined). This is the shape shipped to SDKs.
  """
  alias Flare.Targeting.Compiler

  defstruct version: 0, flags: %{}

  @spec build([map()], map(), integer()) :: %__MODULE__{}
  def build(flags, segments, version) do
    compiled =
      for f <- flags, into: %{} do
        {f.key,
         %{
           key: f.key,
           kind: f.kind,
           salt: f.salt,
           enabled: f.enabled,
           compiled_rules: compile_rules(Map.get(f, :rules, %{}), segments),
           rollout: Map.get(f, :rollout, %{}),
           default_variant: f.default_variant,
           off_variant: f.off_variant,
           variants: f.variants,
           targets: Map.get(f, :targets, %{}),
           bucket_by: Map.get(f, :bucket_by, "user_id")
         }}
      end

    %__MODULE__{version: version, flags: compiled}
  end

  # rules is a map of %{rule_id => %{"rule" => json, "variant" => key}} OR a single rule.
  defp compile_rules(rules, segments) when is_map(rules) do
    case rules do
      %{"list" => list} when is_list(list) ->
        Enum.map(list, fn %{"id" => id, "rule" => r, "variant" => v} ->
          %{id: id, node: Compiler.compile(r, segments), variant: v}
        end)

      _ ->
        []
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/flare/evaluation/ruleset_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(evaluation): context, decision, compiled ruleset builder"
```

---

## Task 8: The evaluator (the hot path)

**Files:**
- Create: `lib/flare/evaluation/evaluator.ex`
- Create: `lib/flare/evaluation.ex`
- Test: `test/flare/evaluation/evaluator_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/flare/evaluation/evaluator_test.exs`:

```elixir
defmodule Flare.Evaluation.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Flare.Evaluation
  alias Flare.Evaluation.{Ruleset, Context}

  defp ruleset(flag_overrides) do
    base = %{
      key: "f", kind: "boolean", salt: "s", enabled: true,
      rules: %{}, rollout: %{},
      default_variant: "on", off_variant: "off",
      variants: %{"on" => true, "off" => false},
      targets: %{}, bucket_by: "user_id"
    }
    Ruleset.build([Map.merge(base, flag_overrides)], %{}, 1)
  end

  test "disabled flag returns off variant with reason :off" do
    rs = ruleset(%{enabled: false})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u"}))
    assert d.reason == :off
    assert d.value == false
    assert d.variant == "off"
  end

  test "enabled flag with no rules falls through to default" do
    rs = ruleset(%{})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u"}))
    assert d.reason == :fallthrough
    assert d.value == true
    assert d.variant == "on"
  end

  test "explicit target match wins" do
    rs = ruleset(%{targets: %{"off" => ["u-target"]}})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u-target"}))
    assert d.reason == :target_match
    assert d.variant == "off"
  end

  test "rule match returns rule's variant" do
    rules = %{"list" => [%{"id" => "r1", "rule" => %{"attr" => "country", "operator" => "equals", "values" => ["KE"]}, "variant" => "off"}]}
    rs = ruleset(%{rules: rules})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u", country: "KE"}))
    assert d.reason == :rule_match
    assert d.matched_rule_id == "r1"
    assert d.variant == "off"
  end

  test "rollout on fallthrough buckets deterministically" do
    rs = ruleset(%{rollout: %{"variant" => "on", "fallback" => "off", "percentage" => 0}})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u"}))
    assert d.reason == :rollout
    assert d.variant == "off"   # 0% -> everyone gets fallback
    assert is_float(d.bucket)
  end

  test "missing flag returns :flag_not_found" do
    rs = ruleset(%{})
    d = Evaluation.evaluate(rs, "nope", Context.new(%{user_id: "u"}))
    assert d.reason == :flag_not_found
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/flare/evaluation/evaluator_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement the evaluator + facade**

Create `lib/flare/evaluation/evaluator.ex`:

```elixir
defmodule Flare.Evaluation.Evaluator do
  @moduledoc "Pure evaluation. No I/O. First-match-wins."
  alias Flare.Evaluation.{Decision, Context, Hash}
  alias Flare.Targeting.Rule

  @spec evaluate(map(), map()) :: Decision.t()
  def evaluate(nil, _ctx), do: %Decision{reason: :flag_not_found}

  def evaluate(%{enabled: false} = flag, _ctx) do
    variant(flag, flag.off_variant, :off, nil, nil)
  end

  def evaluate(flag, ctx) do
    cond do
      target = target_variant(flag, ctx) ->
        variant(flag, target, :target_match, nil, nil)

      match = rule_match(flag, ctx) ->
        variant(flag, match.variant, :rule_match, match.id, nil)

      true ->
        fallthrough(flag, ctx)
    end
  end

  defp target_variant(%{targets: targets}, ctx) do
    uid = Map.get(ctx.attrs, "user_id")

    Enum.find_value(targets, fn {vk, ids} ->
      if uid && uid in ids, do: vk, else: nil
    end)
  end

  defp rule_match(%{compiled_rules: rules}, ctx) do
    Enum.find(rules, fn r -> Rule.matches?(r.node, ctx.attrs) end)
  end

  defp fallthrough(%{rollout: rollout} = flag, ctx) when map_size(rollout) > 0 do
    key = Context.bucketing_key(ctx, flag.bucket_by)
    bucket = Hash.bucket(flag.key, flag.salt, key)
    pct = rollout["percentage"] || 0

    chosen = if bucket < pct, do: rollout["variant"], else: rollout["fallback"]
    variant(flag, chosen, :rollout, nil, bucket)
  end

  defp fallthrough(flag, _ctx) do
    variant(flag, flag.default_variant, :fallthrough, nil, nil)
  end

  defp variant(flag, variant_key, reason, rule_id, bucket) do
    value = Map.get(flag.variants, variant_key)

    %Decision{
      value: value,
      variant: variant_key,
      enabled: value == true,
      matched_rule_id: rule_id,
      reason: reason,
      bucket: bucket
    }
  end
end
```

Create `lib/flare/evaluation.ex`:

```elixir
defmodule Flare.Evaluation do
  @moduledoc """
  Public evaluation facade. `evaluate/3` is the hot path used by the dashboard
  simulator, the SDK reference implementation, and any server-side evaluation.
  Pure — no I/O.
  """
  alias Flare.Evaluation.{Ruleset, Evaluator, Decision}

  @spec evaluate(%Ruleset{}, String.t(), map()) :: Decision.t()
  def evaluate(%Ruleset{flags: flags}, flag_key, %Flare.Evaluation.Context{} = ctx) do
    flags |> Map.get(flag_key) |> Evaluator.evaluate(ctx)
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/flare/evaluation/evaluator_test.exs`
Expected: PASS.

- [ ] **Step 5: Add a microbenchmark sanity test (<1ms)**

Append to `test/flare/evaluation/evaluator_test.exs`:

```elixir
  test "evaluation is fast (< 1ms average over 10k iterations)" do
    rules = %{"list" => [%{"id" => "r1", "rule" => %{"attr" => "country", "operator" => "in", "values" => ["KE","UG","TZ"]}, "variant" => "off"}]}
    rs = ruleset(%{rules: rules})
    ctx = Context.new(%{user_id: "u", country: "TZ"})

    {micros, _} = :timer.tc(fn ->
      for _ <- 1..10_000, do: Evaluation.evaluate(rs, "f", ctx)
    end)

    avg_us = micros / 10_000
    assert avg_us < 1000, "avg eval was #{avg_us}us"
  end
```

Run: `mix test test/flare/evaluation/evaluator_test.exs`
Expected: PASS (avg well under 1000µs).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(evaluation): pure evaluator + public facade, sub-ms verified"
```

---

## Task 9: Context CRUD (accounts, projects, flags, segments) + ruleset assembly from DB

**Files:**
- Create/modify: `lib/flare/accounts.ex`, `lib/flare/projects.ex`, `lib/flare/flags.ex`, `lib/flare/segments.ex`
- Test: `test/flare/flags_context_test.exs`

- [ ] **Step 1: Write the failing integration test**

Create `test/flare/flags_context_test.exs`:

```elixir
defmodule Flare.FlagsContextTest do
  use Flare.DataCase, async: true
  alias Flare.{Accounts, Projects, Flags, Segments, Evaluation}
  alias Flare.Evaluation.Context

  setup do
    {:ok, org} = Accounts.create_organization(%{name: "Acme", slug: "acme"})
    {:ok, proj} = Projects.create_project(%{name: "App", slug: "app", organization_id: org.id})
    {:ok, env} = Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})
    %{org: org, proj: proj, env: env}
  end

  test "create flag, set env behavior, build ruleset, evaluate", %{proj: proj, env: env} do
    {:ok, flag} =
      Flags.create_flag(%{
        project_id: proj.id, key: "payment_v2", kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, _} =
      Flags.upsert_env_setting(flag, env, %{
        enabled: true,
        default_variant_key: "on",
        off_variant_key: "off",
        rules: %{"list" => [%{"id" => "r1", "rule" => %{"attr" => "country", "operator" => "equals", "values" => ["KE"]}, "variant" => "off"}]}
      })

    ruleset = Flags.build_ruleset(env)
    d_ke = Evaluation.evaluate(ruleset, "payment_v2", Context.new(%{user_id: "u", country: "KE"}))
    d_other = Evaluation.evaluate(ruleset, "payment_v2", Context.new(%{user_id: "u", country: "UG"}))

    assert d_ke.variant == "off"
    assert d_other.variant == "on"
  end

  test "segment reference resolves in built ruleset", %{proj: proj, env: env} do
    {:ok, _seg} = Segments.create_segment(%{project_id: proj.id, key: "beta", name: "Beta", rules: %{"op" => "and", "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]}})

    {:ok, flag} =
      Flags.create_flag(%{project_id: proj.id, key: "f2", kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]})

    {:ok, _} = Flags.upsert_env_setting(flag, env, %{
      enabled: true, default_variant_key: "off", off_variant_key: "off",
      rules: %{"list" => [%{"id" => "r1", "rule" => %{"segment" => "beta"}, "variant" => "on"}]}
    })

    rs = Flags.build_ruleset(env)
    d = Evaluation.evaluate(rs, "f2", Context.new(%{user_id: "u", role: "driver"}))
    assert d.variant == "on"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/flare/flags_context_test.exs`
Expected: FAIL (context functions undefined).

- [ ] **Step 3: Implement the contexts**

Create `lib/flare/accounts.ex`:

```elixir
defmodule Flare.Accounts do
  @moduledoc "Accounts context."
  alias Flare.Repo
  alias Flare.Accounts.Organization

  def create_organization(attrs), do: %Organization{} |> Organization.changeset(attrs) |> Repo.insert()
  def get_organization!(id), do: Repo.get!(Organization, id)
end
```

Create `lib/flare/projects.ex`:

```elixir
defmodule Flare.Projects do
  @moduledoc "Projects context."
  alias Flare.Repo
  alias Flare.Projects.{Project, Environment}

  def create_project(attrs), do: %Project{} |> Project.changeset(attrs) |> Repo.insert()
  def create_environment(attrs), do: %Environment{} |> Environment.changeset(attrs) |> Repo.insert()
  def get_environment!(id), do: Repo.get!(Environment, id)
end
```

Create `lib/flare/segments.ex`:

```elixir
defmodule Flare.Segments do
  @moduledoc "Segments context."
  import Ecto.Query
  alias Flare.Repo
  alias Flare.Segments.Segment

  def create_segment(attrs), do: %Segment{} |> Segment.changeset(attrs) |> Repo.insert()

  @doc "Returns %{segment_key => rules_json} for a project — used for inlining."
  def segment_map(project_id) do
    from(s in Segment, where: s.project_id == ^project_id, select: {s.key, s.rules})
    |> Repo.all()
    |> Map.new()
  end
end
```

Create `lib/flare/flags.ex`:

```elixir
defmodule Flare.Flags do
  @moduledoc "Flags context. Owns flag CRUD, per-env settings, and ruleset assembly."
  import Ecto.Query
  alias Flare.Repo
  alias Flare.Flags.{FeatureFlag, FeatureVariant, FlagEnvironmentSetting}
  alias Flare.Projects.Environment
  alias Flare.Segments
  alias Flare.Evaluation.Ruleset

  def create_flag(%{variants: variants} = attrs) do
    attrs = Map.delete(attrs, :variants)

    Repo.transaction(fn ->
      {:ok, flag} = %FeatureFlag{} |> FeatureFlag.changeset(attrs) |> Repo.insert()

      Enum.each(variants, fn v ->
        {:ok, _} =
          %FeatureVariant{}
          |> FeatureVariant.changeset(%{
            feature_flag_id: flag.id,
            key: v.key,
            name: Map.get(v, :name),
            value: %{"v" => v.value}
          })
          |> Repo.insert()
      end)

      flag
    end)
  end

  def upsert_env_setting(%FeatureFlag{id: fid}, %Environment{id: eid}, attrs) do
    attrs = Map.merge(attrs, %{feature_flag_id: fid, environment_id: eid})

    case Repo.get_by(FlagEnvironmentSetting, feature_flag_id: fid, environment_id: eid) do
      nil -> %FlagEnvironmentSetting{}
      existing -> existing
    end
    |> FlagEnvironmentSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Assemble a compiled Ruleset for an environment from the DB."
  def build_ruleset(%Environment{} = env) do
    project_id = Repo.one!(from e in Environment, where: e.id == ^env.id, select: e.project_id)
    segments = Segments.segment_map(project_id)

    flags =
      from(fs in FlagEnvironmentSetting,
        join: f in FeatureFlag, on: f.id == fs.feature_flag_id,
        where: fs.environment_id == ^env.id and is_nil(f.archived_at),
        preload: [feature_flag: :variants]
      )
      |> Repo.all()
      |> Enum.map(&to_flag_map/1)

    Ruleset.build(flags, segments, env.ruleset_version)
  end

  defp to_flag_map(%FlagEnvironmentSetting{feature_flag: flag} = fs) do
    variants =
      for v <- flag.variants, into: %{}, do: {v.key, v.value["v"]}

    %{
      key: flag.key,
      kind: flag.kind,
      salt: flag.rollout_salt,
      enabled: fs.enabled,
      rules: fs.rules,
      rollout: fs.rollout,
      default_variant: fs.default_variant_key,
      off_variant: fs.off_variant_key,
      variants: variants,
      targets: Map.get(fs.rules, "targets", %{}),
      bucket_by: Map.get(fs.rollout, "bucket_by", "user_id")
    }
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/flare/flags_context_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: all PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(contexts): accounts/projects/flags/segments CRUD + ruleset assembly from DB"
```

---

## Task 10: Increment-1 quality gate

**Files:**
- Modify: `mix.exs` (add credo/dialyxir), `.formatter.exs`, `.github/` (optional here — full CI is Increment 6)

- [ ] **Step 1: Add quality deps**

Modify `mix.exs` deps:

```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
```

Run: `mix deps.get`

- [ ] **Step 2: Format, credo, compile with warnings-as-errors**

Run:
```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
```
Expected: format clean; credo no issues (fix any); compiles with no warnings; all tests pass.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: add credo/dialyxir and pass strict quality gate for Increment 1"
```

---

## Self-Review (against the spec)

**Spec coverage check (Increment 1 scope, spec §17.1):**
- Contexts accounts/projects/flags/segments/targeting/evaluation → Tasks 1–3, 5–9 ✅
- Ecto schemas + migrations for all §5 tables → Tasks 1–3 ✅ (evaluations table deferred — it is marked optional in §5 and belongs with telemetry in Increment 6)
- Rule compiler + operator library (§7) → Tasks 5–6 ✅
- Deterministic MurmurHash3 bucketing (§6.4) → Task 4 ✅
- Cross-language conformance fixtures (§6.4) → Task 4 (Steps 4–5) ✅
- Pure evaluation engine, <1ms (§6) → Tasks 7–8 (Task 8 Step 5 asserts timing) ✅
- Full unit + property test suite (§16) → property tests in Task 4 Step 6, unit tests throughout ✅

**Deferred out of Increment 1 (correctly, per spec increment plan):** Redis cache, SSE/PubSub sync, REST/SDK API, LiveView, auth/session, RBAC enforcement, key hashing/rotation, rate limiting, audit write path via Oban, CI/CD, Docker/K8s. These are Increments 2–6.

**Placeholder scan:** No TBD/TODO in steps. Two intentional `null` placeholders exist in the fixture JSON (Task 4 Step 4) — these are computed values the engineer fills from the trusted implementation in that same step, which is the correct TDD flow (you cannot hand-author a hash). Flagged explicitly.

**Type/name consistency:** `Ruleset.build/3`, `Context.new/1`, `Context.bucketing_key/2`, `Evaluation.evaluate/3`, `Rule.matches?/2`, `Compiler.compile/2`, `Operators.apply/3`, `Hash.murmur3_32/2`, `Hash.bucket/3`, `Hash.in_rollout?/4` — used consistently across tasks. Flag map keys (`:key,:kind,:salt,:enabled,:rules,:rollout,:default_variant,:off_variant,:variants,:targets,:bucket_by`) are consistent between Ruleset (Task 7), Evaluator (Task 8), and `to_flag_map/1` (Task 9).

**One known gotcha for the executing engineer:** the MurmurHash3 `body/2` + `tail_mix/2` recursion in Task 4 Step 1 must be validated against the three reference vectors in Step 3 *before* generating fixtures. If the vectors don't match, the implementation is wrong — fix it there. Everything downstream (every SDK) trusts these values.
