defmodule Domain.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:users) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )
    end
  end
end
