defmodule FzHttp.Repo.Migrations.ChangeAllowedIpsToText do
  use Ecto.Migration

  def up do
    alter table("devices") do
      modify :allowed_ips, :text, default: nil
    end

    alter table("sites") do
      modify :allowed_ips, :text, default: nil
    end
  end

  def down do
    alter table("devices") do
      modify :allowed_ips, :string, default: nil
    end

    alter table("sites") do
      modify :allowed_ips, :string, default: nil
    end
  end
end
