defmodule Domain.Repo.Migrations.CreateEntraGroupInclusions do
  use Ecto.Migration

  def change do
    create table(:entra_group_inclusions, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :directory_id,
        references(:entra_directories, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:external_id, :string, null: false, primary_key: true)

      timestamps(updated_at: false)
    end

    # For preloads and cascading deletes
    create(index(:entra_group_inclusions, :directory_id))
  end
end
