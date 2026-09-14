defmodule Portal.Policies.Postures.Revocation do
  @moduledoc """
  Re-checks the posture policies an account's clients hold authorizations for
  and revokes the ones that stopped holding.

  A provider sync runs this once it has written its rows. A connected client
  refreshes its own resource list from the change feed, but an offline client
  would otherwise keep its flows alive on the gateway until the authorization
  expires, so the check is tied to the sync rather than to the connection.
  """

  alias __MODULE__.Database
  alias Portal.Devices.Posture
  alias Portal.Policies.Postures

  @spec revoke_stale_authorizations(Ecto.UUID.t()) :: :ok
  def revoke_stale_authorizations(account_id) do
    now = DateTime.utc_now()

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

    if stale != [] do
      Database.delete_policy_authorizations(account_id, stale)
    end

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Device, Policy, PolicyAuthorization, Safe}

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
