defmodule CfPhx.Repo do
  use Ecto.Repo,
    otp_app: :cf_phx,
    adapter: Ecto.Adapters.Postgres
end
