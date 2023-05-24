defmodule Domain.Repo.Migrations.RenameUseDefaultToUseSite do
  use Ecto.Migration

  def change do
    rename(table(:devices), :use_default_allowed_ips, to: :use_site_allowed_ips)
    rename(table(:devices), :use_default_dns, to: :use_site_dns)
    rename(table(:devices), :use_default_endpoint, to: :use_site_endpoint)
    rename(table(:devices), :use_default_persistent_keepalive, to: :use_site_persistent_keepalive)
    rename(table(:devices), :use_default_mtu, to: :use_site_mtu)
  end
end
