defmodule Domain.Clients.Presence do
  use Phoenix.Presence,
    otp_app: :domain,
    pubsub_server: Domain.PubSub

  alias Domain.PubSub
  alias Domain.Clients.Client

  def connect(%Client{} = client, token_id) do
    with {:ok, _} <- __MODULE__.Account.track(client.account_id, client.id),
         {:ok, _} <- __MODULE__.Actor.track(client.actor_id, client.id, token_id) do
      :ok
    end
  end

  defmodule Account do
    def track(account_id, client_id) do
      Domain.Clients.Presence.track(
        self(),
        topic(account_id),
        client_id,
        %{online_at: System.system_time(:second)}
      )
    end

    def subscribe(account_id) do
      account_id
      |> topic()
      |> PubSub.subscribe()
    end

    def get(account_id, client_id) do
      account_id
      |> topic()
      |> Domain.Clients.Presence.get_by_key(client_id)
    end

    def list(account_id) do
      account_id
      |> topic()
      |> Domain.Clients.Presence.list()
    end

    defp topic(account_id) do
      "presences:account_clients:" <> account_id
    end
  end

  defmodule Actor do
    def track(actor_id, client_id, token_id) do
      Domain.Clients.Presence.track(
        self(),
        topic(actor_id),
        client_id,
        %{token_id: token_id}
      )
    end

    def get(actor_id, client_id) do
      actor_id
      |> topic()
      |> Domain.Clients.Presence.get_by_key(client_id)
    end

    def list(actor_id) do
      actor_id
      |> topic()
      |> Domain.Clients.Presence.list()
    end

    def subscribe(actor_id) do
      actor_id
      |> topic()
      |> PubSub.subscribe()
    end

    defp topic(actor_id) do
      "presences:actor_clients:" <> actor_id
    end
  end
end
