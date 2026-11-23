defmodule Portal.Repo.Migrations.CreateMetricsDiagnostics do
  use Ecto.Migration

  def change do
    create table(:metrics_diagnostics, primary_key: false) do
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :actor_id,
          references(:actors,
            with: [account_id: :account_id],
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false,
          primary_key: true

      add :expires_at, :utc_datetime_usec, null: false

      timestamps()
    end
  end
end
