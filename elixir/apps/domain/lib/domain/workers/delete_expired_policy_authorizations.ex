defmodule Domain.Workers.DeleteExpiredPolicyAuthorizations do
  @moduledoc """
  Oban worker that deletes expired policy authorizations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.DB

  require Logger

  @impl Oban.Worker
  def perform(_args) do
    {count, nil} = DB.delete_expired_policy_authorizations()

    Logger.info("Deleted #{count} expired policy authorizations")

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, PolicyAuthorization}

    def delete_expired_policy_authorizations do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
