defmodule Domain.Workers.DeleteExpiredFlows do
  @moduledoc """
  Oban worker that deletes expired flows.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity]

  require Logger

  @impl Oban.Worker
  def perform(_args) do
    {count, nil} = delete_expired_flows()

    Logger.info("Deleted #{count} expired flows")

    :ok
  end

  # Inline function from Domain.Flows
  defp delete_expired_flows do
    import Ecto.Query

    from(f in Domain.Flow, as: :flows)
    |> where([flows: f], f.expires_at <= ^DateTime.utc_now())
    |> Domain.Safe.unscoped()
    |> Domain.Safe.delete_all()
  end
end
