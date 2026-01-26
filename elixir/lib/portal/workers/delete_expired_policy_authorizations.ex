defmodule Portal.Workers.DeleteExpiredPolicyAuthorizations do
  @moduledoc """
  Oban worker that deletes expired policy authorizations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: 1}) do
    # Snooze 30s on first attempt to avoid deadlocks with DeleteExpiredClientTokens
    # which runs at the start of every 5th minute and cascades deletes to this table
    {:snooze, 30}
  end

  def perform(_job) do
    {count, nil} = Database.delete_expired_policy_authorizations()

    Logger.info("Deleted #{count} expired policy authorizations")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, PolicyAuthorization}

    def delete_expired_policy_authorizations do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
