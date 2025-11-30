defmodule Domain.Gateways.Presence do
  use Phoenix.Presence,
    otp_app: :domain,
    pubsub_server: Domain.PubSub

  alias Domain.Gateway
  alias Domain.PubSub

  def connect(%Gateway{} = gateway, token_id) do
    with {:ok, _} <- __MODULE__.Site.track(gateway.site_id, gateway.id, token_id),
         {:ok, _} <- __MODULE__.Account.track(gateway.account_id, gateway.id) do
      :ok
    end
  end

  @doc false
  def preload_gateways_presence([gateway]) do
    __MODULE__.Account.get(gateway.account_id, gateway.id)
    |> case do
      [] -> %{gateway | online?: false}
      %{metas: [_ | _]} -> %{gateway | online?: true}
    end
    |> List.wrap()
  end

  def preload_gateways_presence(gateways) do
    # we fetch list of account gateways for every account_id present in the gateways list
    connected_gateways =
      gateways
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn account_id, acc ->
        connected_gateways = __MODULE__.Account.list(account_id)
        Map.merge(acc, connected_gateways)
      end)

    Enum.map(gateways, fn gateway ->
      %{gateway | online?: Map.has_key?(connected_gateways, gateway.id)}
    end)
  end

  defmodule Account do
    def track(account_id, gateway_id) do
      Domain.Gateways.Presence.track(
        self(),
        topic(account_id),
        gateway_id,
        %{online_at: System.system_time(:second)}
      )
    end

    def subscribe(account_id) do
      account_id
      |> topic()
      |> PubSub.subscribe()
    end

    def get(account_id, gateway_id) do
      account_id
      |> topic()
      |> Domain.Gateways.Presence.get_by_key(gateway_id)
    end

    def list(account_id) do
      account_id
      |> topic()
      |> Domain.Gateways.Presence.list()
    end

    defp topic(account_id) do
      "presences:account_gateways:" <> account_id
    end
  end

  defmodule Site do
    def track(site_id, gateway_id, token_id) do
      Domain.Gateways.Presence.track(
        self(),
        topic(site_id),
        gateway_id,
        %{token_id: token_id}
      )
    end

    def subscribe(site_id) do
      site_id
      |> topic()
      |> PubSub.subscribe()
    end

    def list(site_id) do
      site_id
      |> topic()
      |> Domain.Gateways.Presence.list()
    end

    defp topic(site_id) do
      "presences:sites:" <> site_id
    end
  end
end
