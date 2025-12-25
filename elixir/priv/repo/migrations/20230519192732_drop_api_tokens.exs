defmodule Portal.Repo.Migrations.DropApiTokens do
  use Ecto.Migration

  def change do
    drop(table(:api_tokens))
  end
end
