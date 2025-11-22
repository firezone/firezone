defmodule Domain.Repo.Migrations.CreateDirectoriesTable do
  use Domain, :migration

  def change do
    create(table(:directories, primary_key: false)) do
      account(primary_key: true)
      add(:id, :binary_id, null: false, primary_key: true)
      add(:type, :string, null: false)
    end

    create(
      constraint(:directories, :type_must_be_valid, check: "type IN ('google', 'entra', 'okta')")
    )
  end
end
