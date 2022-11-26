defmodule FzHttp.Repo.Migrations.AddRevokedTokensToConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add(:revoked_tokens, :map)
    end
  end
end
