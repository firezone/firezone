defmodule FzHttp.Repo.Migrations.ChangeAllowedIpsToText do
  use Ecto.Migration

  def change do
    alter table("devices") do
      modify :allowed_ips, :text, default: nil
    end
  end
end
