defmodule Domain.Repo.Migrations.CreateAuthProvidersTable do
  use Domain, :migration

  def change do
    create(table(:auth_providers, primary_key: false)) do
      account(primary_key: true)
      add(:id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()"))
    end
  end
end
