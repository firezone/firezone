defmodule Portal.Workers.DeleteExpiredPolicyAuthorizations do
  @moduledoc """
  Oban worker that deletes expired policy authorizations and the ones of
  disabled actors. The actor change hook deletes the latter when the actor is
  disabled; this also catches authorizations still queued at that time.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: 1}) do
    # Snooze 30s on first attempt to avoid deadlocks with DeleteExpiredClientTokens
    # which runs at the start of every 5th minute and cascades deletes to this table
    {:snooze, 30}
  end

  def perform(_job) do
    {expired, nil} = Database.delete_expired_policy_authorizations()

    Logger.info("Deleted #{expired} expired policy authorizations")

    {disabled, nil} = Database.delete_disabled_actor_policy_authorizations()

    Logger.info("Deleted #{disabled} policy authorizations of disabled actors")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Actor, DeviceToken, PolicyAuthorization, Safe}

    def delete_expired_policy_authorizations do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_disabled_actor_policy_authorizations do
      from(pa in PolicyAuthorization,
        join: t in DeviceToken,
        on: t.account_id == pa.account_id and t.id == pa.token_id,
        join: a in Actor,
        on: a.account_id == t.account_id and a.id == t.actor_id,
        where: a.is_disabled
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
