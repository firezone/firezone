defmodule FzHttp.Repo.Migrations.TrimDNSFields do
  use Ecto.Migration

  def change do
    execute("""
    UPDATE devices
    SET dns = string_to_array(
                trim(
                  both ' ' from regexp_replace(
                    array_to_string(dns, ','),
                    '\s*,\s*',
                    ','
                  )
                ),
                ','
              )
    """)

    execute("""
    UPDATE configurations
    SET default_client_dns = string_to_array(
                trim(
                  both ' ' from regexp_replace(
                    array_to_string(default_client_dns, ','),
                    '\s*,\s*',
                    ','
                  )
                ),
                ','
              )
    """)
  end
end
