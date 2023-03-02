defmodule FzHttp.Repo.Migrations.TrimDNSFields do
  use Ecto.Migration

  def change do
    execute("""
    UPDATE devices
    SET dns = string_to_array(
                replace(
                  array_to_string(dns, ','),
                  ' ',
                  ''
                ),
                ','
              )
    """)

    execute("""
    UPDATE configurations
    SET default_client_dns = string_to_array(
                replace(
                  array_to_string(default_client_dns, ','),
                  ' ',
                  ''
                ),
                ','
              )
    """)
  end
end
