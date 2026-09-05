defmodule Portal.Repo.Lock do
  @moduledoc """
  Isolated direct pool for session advisory locks.

  A session lock lives on one server connection, so it cannot go through
  PgBouncer's transaction pooling, and a holder keeps its connection checked
  out for as long as the locked work runs, which must not starve the shared
  pools.
  """

  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
