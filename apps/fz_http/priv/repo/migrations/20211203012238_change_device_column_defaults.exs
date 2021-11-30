defmodule FzHttp.Repo.Migrations.ChangeDeviceColumnDefaults do
  @moduledoc """
  Removes the device defaults in favor of using values from the
  settings table.
  """
  use Ecto.Migration

  def change do
    alter table("devices") do
      add :use_default_endpoint, :boolean, default: true, null: false
      add :use_default_allowed_ips, :boolean, default: true, null: false
      add :use_default_dns_servers, :boolean, default: true, null: false
      add :endpoint, :string, default: nil
      modify :allowed_ips, :string, default: nil
      modify :dns_servers, :string, default: nil
    end
  end
end
