defmodule Domain.Repo.Migrations.CreateAuthProvidersTable do
  use Domain, :migration

  def change do
    create(table(:auth_providers, primary_key: false)) do
      account(primary_key: true)
      add(:id, :binary_id, null: false, primary_key: true)
    end
  end
end
