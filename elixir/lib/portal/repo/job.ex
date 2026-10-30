defmodule Portal.Repo.Job do
  @moduledoc """
  Isolated connection pool for Oban and the domain queries executed by its workers.

  Keeping job traffic separate prevents background work from exhausting the Web
  or API pools while PgBouncer can still multiplex all three workloads onto the
  same upstream PostgreSQL connection pool.
  """

  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres
end
