defmodule FzHttp.Repo.Migrations.ChangeRefreshTokenToText do
  use Ecto.Migration

  def change do
    alter table("oidc_connections") do
      modify(:refresh_token, :text)
    end
  end
end
