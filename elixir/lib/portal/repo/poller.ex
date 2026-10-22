defmodule Portal.Repo.Poller do
  @moduledoc """
  Isolated primary pool for the replication slot pollers.

  Poll cycles hold a checked-out connection for as long as a cycle runs
  (leadership advisory locks, WAL decoding), which must not starve the
  shared pools.
  """

  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
