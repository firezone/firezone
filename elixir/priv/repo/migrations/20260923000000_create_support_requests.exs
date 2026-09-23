defmodule Portal.Repo.Migrations.CreateSupportRequests do
  use Ecto.Migration

  def change do
    create table(:support_requests, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:support_requests, [:account_id, :inserted_at]))
  end
end
