defmodule FzHttp.Repo do
  use Ecto.Repo,
    otp_app: :fz_http,
    adapter: Ecto.Adapters.Postgres

  require Logger
end
