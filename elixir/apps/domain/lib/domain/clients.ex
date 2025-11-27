defmodule Domain.Clients do
  use Supervisor
  alias Domain.Clients.Presence

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Keep these presence-related functions as they're used throughout the app
  @doc false
  def preload_clients_presence([client]) do
    Presence.Account.get(client.account_id, client.id)
    |> case do
      [] -> %{client | online?: false}
      %{metas: [_ | _]} -> %{client | online?: true}
    end
    |> List.wrap()
  end

  def preload_clients_presence(clients) do
    # we fetch list of account clients for every account_id present in the clients list
    connected_clients =
      clients
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce([], fn account_id, acc ->
        connected_client_ids = online_client_ids(account_id)
        connected_client_ids ++ acc
      end)

    Enum.map(clients, fn client ->
      %{client | online?: client.id in connected_clients}
    end)
  end

  def online_client_ids(account_id) do
    account_id
    |> Presence.Account.list()
    |> Map.keys()
  end
end