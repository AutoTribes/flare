defmodule Flare.Repo.Migrations.CreateFlags do
  use Ecto.Migration

  def change do
    create table(:feature_flags, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

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

      add :feature_flag_id, references(:feature_flags, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :name, :string
      add :value, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:feature_variants, [:feature_flag_id, :key])

    create table(:flag_environment_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :feature_flag_id, references(:feature_flags, type: :binary_id, on_delete: :delete_all),
        null: false

      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all),
        null: false

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

      add :feature_flag_id, references(:feature_flags, type: :binary_id, on_delete: :delete_all),
        null: false

      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all),
        null: false

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

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :name, :string, null: false
      add :rules, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:segments, [:project_id, :key])

    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

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
