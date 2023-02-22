defmodule FzHttp.Repo.Migrations.ChangeDnsAndAllowedIpsToInetArray do
  use Ecto.Migration

  def change do
    rename(table(:configurations), :default_client_dns, to: :default_client_dns_string)

    rename(table(:configurations), :default_client_allowed_ips,
      to: :default_client_allowed_ips_string
    )

    rename(table(:devices), :dns, to: :dns_string)
    rename(table(:devices), :allowed_ips, to: :allowed_ips_string)

    alter table(:configurations) do
      add(:default_client_dns, {:array, :string}, default: [])
      add(:default_client_allowed_ips, {:array, :inet}, default: [])
    end

    alter table(:devices) do
      add(:dns, {:array, :string}, default: [])
      add(:allowed_ips, {:array, :inet}, default: [])
    end

    execute("""
    UPDATE configurations
    SET default_client_dns = string_to_array(trim(both ' ' from regexp_replace(default_client_dns_string, '\s*,\s*', ',')), ','),
        default_client_allowed_ips = string_to_array(trim(both ' ' from regexp_replace(default_client_allowed_ips_string, '\s*,\s*', ',')), ',')::inet[]
    """)

    execute("""
    UPDATE devices
    SET dns = string_to_array(dns_string, ','),
        allowed_ips = string_to_array(trim(both ' ' from regexp_replace(allowed_ips_string, '\s*,\s*', ',')), ',')::inet[]
    """)

    alter table(:configurations) do
      remove(:default_client_dns_string, :string)
      remove(:default_client_allowed_ips_string, :string)
    end

    alter table(:devices) do
      remove(:dns_string, :string)
      remove(:allowed_ips_string, :string)
    end
  end
end
