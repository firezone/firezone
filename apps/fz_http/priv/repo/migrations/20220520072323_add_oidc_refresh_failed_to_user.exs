defmodule FzHttp.Repo.Migrations.AddOidcRefreshFailedToUser do
  use Ecto.Migration

  def change do
    alter table("users") do
      add :allowed_to_connect, :boolean, default: true, null: false
    end
  end
end
