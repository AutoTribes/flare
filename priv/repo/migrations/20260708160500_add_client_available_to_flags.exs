defmodule Flare.Repo.Migrations.AddClientAvailableToFlags do
  use Ecto.Migration

  def change do
    alter table(:feature_flags) do
      add :client_available, :boolean, null: false, default: true
    end
  end
end
