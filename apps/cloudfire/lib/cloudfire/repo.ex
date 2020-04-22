defmodule Cloudfire.Repo do
  use Ecto.Repo,
    otp_app: :cloudfire,
    adapter: Ecto.Adapters.Postgres
end
