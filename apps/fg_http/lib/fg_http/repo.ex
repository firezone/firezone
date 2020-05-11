defmodule FgHttp.Repo do
  use Ecto.Repo,
    otp_app: :fg_http,
    adapter: Ecto.Adapters.Postgres
end
