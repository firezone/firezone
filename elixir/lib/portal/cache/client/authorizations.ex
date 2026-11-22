defmodule Portal.Cache.Client.Authorizations do
  @moduledoc """
    Loads a client's authorizations into two `Portal.Cache.Authorizations` caches when its channel
    joins: inbound, where the client is the receiving device, and outbound, where it is the
    initiating device and the receiving device is another client or a pool target.
  """

  alias Portal.{Cache, Device}
  alias __MODULE__.Database

  require OpenTelemetry.Tracer

  @doc """
    Fetches the client's policy_authorizations with one query and returns two caches: inbound,
    where the client is the receiving device, and outbound, where the client is the initiating
    device and the receiving device is another client. When more than one non-expired
    authorization exists for a pair, the longest-expiring one is kept to minimize unnecessary
    access churn.
  """
  @spec hydrate(Device.t()) ::
          {inbound :: Cache.Authorizations.t(), outbound :: Cache.Authorizations.t()}
  def hydrate(client) do
    OpenTelemetry.Tracer.with_span "Portal.Cache.Client.Authorizations.hydrate",
      attributes: %{
        client_id: client.id,
        account_id: client.account_id
      } do
      Database.all_client_policy_authorizations_for_cache!(client)
      |> Enum.reduce({%{}, %{}}, fn {id, initiating_id, receiving_id, resource_id, expires_at},
                                    {inbound, outbound} ->
        inbound =
          if receiving_id == client.id do
            Cache.Authorizations.put_longest(inbound, id, initiating_id, resource_id, expires_at)
          else
            inbound
          end

        outbound =
          if initiating_id == client.id do
            Cache.Authorizations.put_longest(outbound, id, receiving_id, resource_id, expires_at)
          else
            outbound
          end

        {inbound, outbound}
      end)
    end
  end

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def all_client_policy_authorizations_for_cache!(%{account_id: _, id: _} = client) do
      now = DateTime.utc_now()

      from(pa in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> join(:inner, [policy_authorizations: pa], d in Portal.Device,
        on: d.account_id == pa.account_id and d.id == pa.receiving_device_id,
        as: :receiving_device
      )
      |> where([policy_authorizations: pa], pa.account_id == ^client.account_id)
      # A gateway on `/device/v1` can be a pool target too.
      |> where(
        [policy_authorizations: pa, receiving_device: d],
        pa.receiving_device_id == ^client.id or
          (pa.initiating_device_id == ^client.id and
             (d.type == :client or
                exists(
                  from(r in Portal.Resource,
                    where:
                      r.account_id == parent_as(:policy_authorizations).account_id and
                        r.id == parent_as(:policy_authorizations).resource_id and
                        r.type == :device_pool
                  )
                )))
      )
      |> where([policy_authorizations: pa], pa.expires_at > ^now)
      # Longest-expiring first so the per-pair last-one-wins reduction is deterministic.
      |> order_by([policy_authorizations: pa], desc: pa.expires_at)
      |> select(
        [policy_authorizations: pa],
        {pa.id, pa.initiating_device_id, pa.receiving_device_id, pa.resource_id, pa.expires_at}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
