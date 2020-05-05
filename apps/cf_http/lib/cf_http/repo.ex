defmodule CfHttp.Repo do
  use Ecto.Repo,
    otp_app: :cf_http,
    adapter: Ecto.Adapters.Postgres
end
