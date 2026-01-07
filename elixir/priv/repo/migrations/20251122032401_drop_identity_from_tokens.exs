defmodule Portal.Repo.Migrations.DropIdentityFromTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      remove(:identity_id)
    end
  end
end
