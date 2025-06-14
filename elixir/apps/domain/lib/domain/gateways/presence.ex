defmodule Domain.Gateways.Presence do
  use Phoenix.Presence,
    otp_app: :domain,
    pubsub_server: Domain.PubSub

  alias Domain.Gateways.Gateway
  alias Domain.PubSub

  def connect(%Gateway{} = gateway) do
    with {:ok, _} <- __MODULE__.Group.track(gateway.group_id, gateway.id),
         {:ok, _} <- __MODULE__.Account.track(gateway.account_id, gateway.id) do
      :ok = PubSub.Gateway.subscribe(gateway.id)
    end
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

  defmodule Group do
    def track(gateway_group_id, gateway_id) do
      Domain.Gateways.Presence.track(
        self(),
        topic(gateway_group_id),
        gateway_id,
        %{}
      )
    end

    def subscribe(gateway_group_id) do
      gateway_group_id
      |> topic()
      |> PubSub.subscribe()
    end

    def list(gateway_group_id) do
      gateway_group_id
      |> topic()
      |> Domain.Gateways.Presence.list()
    end

    defp topic(gateway_group_id) do
      "presences:group_gateways:" <> gateway_group_id
    end
  end
end
