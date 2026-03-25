defmodule Portal.Repo.Web do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres
end
