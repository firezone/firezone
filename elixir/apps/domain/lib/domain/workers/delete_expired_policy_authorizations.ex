defmodule Domain.Workers.DeleteExpiredPolicyAuthorizations do
  @moduledoc """
  Oban worker that deletes expired policy authorizations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity]

  require Logger

  @impl Oban.Worker
  def perform(_args) do
    {count, nil} = delete_expired_policy_authorizations()

    Logger.info("Deleted #{count} expired policy authorizations")

    :ok
  end

  # Inline function from Domain.PolicyAuthorizations
  defp delete_expired_policy_authorizations do
    import Ecto.Query

    from(pa in Domain.PolicyAuthorization, as: :policy_authorizations)
    |> where([policy_authorizations: pa], pa.expires_at <= ^DateTime.utc_now())
    |> Domain.Safe.unscoped()
    |> Domain.Safe.delete_all()
  end
end
