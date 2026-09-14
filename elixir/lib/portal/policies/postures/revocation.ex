defmodule Portal.Policies.Postures.Revocation do
  @moduledoc """
  Re-checks the posture policies an account's clients hold authorizations for
  and revokes the ones that stopped holding.

  A provider sync runs this once it has written its rows. A connected client
  refreshes its own resource list from the change feed, but an offline client
  would otherwise keep its flows alive on the gateway until the authorization
  expires, so the check is tied to the sync rather than to the connection.
  """

  import Ecto.Query

  alias Portal.{Device, Policy, PolicyAuthorization, Safe}
  alias Portal.Devices.Posture
  alias Portal.Policies.Postures

  @spec revoke_stale_authorizations(Ecto.UUID.t()) :: :ok
  def revoke_stale_authorizations(account_id) do
    now = DateTime.utc_now()

    account_id
    |> list_authorized_posture_policies(now)
    |> Enum.group_by(fn {client, _policy} -> client end, fn {_client, policy} -> policy end)
    |> Enum.each(fn {client, policies} -> revoke_for_client(client, policies, now) end)
  end

  defp revoke_for_client(client, policies, now) do
    client = %{client | posture: Posture.rows_by_type(client)}

    stale =
      for policy <- policies,
          {:error, _violations} <- [Postures.Evaluator.evaluate(policy.postures, client, now)],
          do: policy.id

    if stale != [] do
      delete_policy_authorizations(client, stale)
    end
  end

  defp list_authorized_posture_policies(account_id, now) do
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

  defp delete_policy_authorizations(%Device{} = client, policy_ids) do
    from(a in PolicyAuthorization,
      where: a.account_id == ^client.account_id and a.initiating_device_id == ^client.id,
      where: a.policy_id in ^policy_ids
    )
    |> Safe.unscoped()
    |> Safe.delete_all()
  end
end
