defmodule Portal.Repo.Replica.Poller do
  @moduledoc """
  Isolated replica pool for `Portal.Changes.Consumer` WAL decoding; see
  `Portal.Repo.Poller`.
  """

  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
