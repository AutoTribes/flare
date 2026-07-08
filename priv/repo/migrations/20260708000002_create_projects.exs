defmodule Flare.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:organization_id, :slug])

    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :key, :string, null: false
      add :ruleset_version, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:environments, [:project_id, :key])

    create table(:sdk_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all),
        null: false

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

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

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
