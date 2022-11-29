defmodule FzHttp.Repo.Migrations.ChangeApiTokensRevokedAtIndexToPartial do
  use Ecto.Migration

  def change do
    drop(index(:api_tokens, [:revoked_at]))
    create(index(:api_tokens, [:revoked_at], where: "revoked_at IS NOT NULL"))
  end
end
