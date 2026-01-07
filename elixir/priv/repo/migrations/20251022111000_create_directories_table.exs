defmodule Portal.Repo.Migrations.CreateDirectoriesTable do
  use Ecto.Migration

  def change do
    create(table(:directories, primary_key: false)) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:type, :string, null: false)
    end

    create(
      constraint(:directories, :type_must_be_valid, check: "type IN ('google', 'entra', 'okta')")
    )
  end
end
