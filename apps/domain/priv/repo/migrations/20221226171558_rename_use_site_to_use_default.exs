defmodule Domain.Repo.Migrations.RenameUseSiteToUseDefault do
  use Ecto.Migration

  def change do
    rename(table(:devices), :use_site_allowed_ips, to: :use_default_allowed_ips)
    rename(table(:devices), :use_site_dns, to: :use_default_dns)
    rename(table(:devices), :use_site_endpoint, to: :use_default_endpoint)
    rename(table(:devices), :use_site_mtu, to: :use_default_mtu)
    rename(table(:devices), :use_site_persistent_keepalive, to: :use_default_persistent_keepalive)
  end
end
