defmodule Portal.Repo.Replica do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
