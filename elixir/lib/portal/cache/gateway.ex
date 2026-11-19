defmodule Portal.Cache.Gateway do
  @moduledoc """
    Loads the authorizations a gateway has been told about into a `Portal.Cache.Authorizations`
    cache when its channel joins. WAL messages from `Portal.Changes.Consumer` keep it current.
  """

  alias Portal.{Cache, Device}
  alias __MODULE__.Database

  require OpenTelemetry.Tracer

  @doc """
    Fetches relevant policy_authorizations from the DB and transforms them into the cache format.
    When more than one non-expired authorization exists for a pair, the longest-expiring one is
    kept to minimize unnecessary access churn.
  """
  @spec hydrate(Device.t()) :: Cache.Authorizations.t()
  def hydrate(gateway) do
    OpenTelemetry.Tracer.with_span "Portal.Cache.hydrate_policy_authorizations",
      attributes: %{
        gateway_id: gateway.id,
        account_id: gateway.account_id
      } do
      Database.all_gateway_policy_authorizations_for_cache!(gateway)
      |> Enum.reduce(%{}, fn {id, client_id, resource_id, expires_at}, cache ->
        Cache.Authorizations.put_longest(cache, id, client_id, resource_id, expires_at)
      end)
    end
  end

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def all_gateway_policy_authorizations_for_cache!(%{account_id: _, id: _} = gateway) do
      now = DateTime.utc_now()

      from(f in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^gateway.account_id)
      |> where([policy_authorizations: f], f.receiving_device_id == ^gateway.id)
      |> where([policy_authorizations: f], f.expires_at > ^now)
      # Longest-expiring first so the per-pair last-one-wins reduction is deterministic.
      |> order_by([policy_authorizations: f], desc: f.expires_at)
      |> select(
        [policy_authorizations: f],
        {f.id, f.initiating_device_id, f.resource_id, f.expires_at}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
