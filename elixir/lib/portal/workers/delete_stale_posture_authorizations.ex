defmodule Portal.Workers.DeleteStalePostureAuthorizations do
  @moduledoc """
  Re-checks the posture policies clients hold authorizations for and deletes
  the ones that stopped holding.

  A connected client keeps its own resource list current from the change feed
  and its minute timer, but an offline client would otherwise keep its flows
  alive on the gateway until the authorization expires. This also catches what
  no row change announces: a provider that was disabled or deleted, a new OS
  or Client release, and time-based rules aging out.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database
  alias Portal.Devices.Posture
  alias Portal.Policies.Postures

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    count =
      now
      |> Database.list_account_ids()
      |> Enum.map(&delete_stale(&1, now))
      |> Enum.sum()

    Logger.info("Deleted #{count} stale posture policy authorizations")

    :ok
  end

  defp delete_stale(account_id, now) do
    policies_by_client =
      account_id
      |> Database.list_authorized_posture_policies(now)
      |> Enum.group_by(fn {client, _policy} -> client end, fn {_client, policy} -> policy end)

    rows_by_client = policies_by_client |> Map.keys() |> Posture.rows_by_type_all()

    stale =
      for {client, policies} <- policies_by_client,
          client = %{client | posture: Map.get(rows_by_client, client.id, %{})},
          policy <- policies,
          {:error, _violations} <- [Postures.Evaluator.evaluate(policy.postures, client, now)],
          do: {client.id, policy.id}

    if stale == [] do
      0
    else
      {count, nil} = Database.delete_policy_authorizations(account_id, stale)
      count
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Device, Policy, PolicyAuthorization, Safe}

    def list_account_ids(now) do
      from(a in PolicyAuthorization,
        join: p in Policy,
        on: p.account_id == a.account_id and p.id == a.policy_id,
        where: a.expires_at > ^now and not is_nil(p.postures),
        distinct: true,
        select: a.account_id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def list_authorized_posture_policies(account_id, now) do
      from(a in PolicyAuthorization,
        join: d in Device,
        on: d.account_id == a.account_id and d.id == a.initiating_device_id,
        join: p in Policy,
        on: p.account_id == a.account_id and p.id == a.policy_id,
        where: a.account_id == ^account_id and a.expires_at > ^now,
        where: d.type == :client and not is_nil(p.postures),
        distinct: true,
        select: {d, p}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def delete_policy_authorizations(account_id, client_and_policy_ids) do
      pairs =
        Enum.map(client_and_policy_ids, fn {client_id, policy_id} ->
          dynamic([a], a.initiating_device_id == ^client_id and a.policy_id == ^policy_id)
        end)

      from(a in PolicyAuthorization, where: a.account_id == ^account_id)
      |> where(^Enum.reduce(pairs, &dynamic(^&1 or ^&2)))
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
