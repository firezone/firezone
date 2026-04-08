defmodule Portal.Repo.Api do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres
end
