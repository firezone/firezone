defmodule Portal.PubSub do
  @moduledoc """
  A wrapper around Phoenix.PubSub that allows us not to spread the knowledge of the process name
  across applications.
  """
  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(_opts) do
    children = [
      {Phoenix.PubSub, name: __MODULE__}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  See `Phoenix.PubSub.broadcast/3`.

  Keep in mind that Phoenix.Presence is also using the same PubSub process,
  so you can broadcast to Phoenix.Presence topics as well. This feature is
  used in some of domain contexts.
  """
  def broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(__MODULE__, topic, payload)
  end

  @doc """
  See `Phoenix.PubSub.subscribe/2`.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(__MODULE__, topic)
  end

  @doc """
  See `Phoenix.PubSub.unsubscribe/2`.
  """
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(__MODULE__, topic)
  end

  defmodule Changes do
    def subscribe(account_id) do
      account_id
      |> topic()
      |> Portal.PubSub.subscribe()
    end

    def broadcast(account_id, payload) do
      topic = topic(account_id)
      region = Portal.Config.get_env(:portal, :region, "")

      for node <- target_nodes(region) do
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, topic, payload)
      end

      :ok
    end

    defp topic(account_id) do
      Atom.to_string(__MODULE__) <> ":" <> account_id
    end

    # In dev / test region we don't have a cluster / region; send to self
    defp target_nodes(""), do: [Node.self()]

    # Node names: portal-{region}-{type}-{index}-{hash}@{ip}
    defp target_nodes(region) do
      web_prefix = "portal-" <> region <> "-web"
      api_prefix = "portal-" <> region <> "-api"

      Node.list()
      |> Enum.filter(fn node ->
        name = Atom.to_string(node)
        String.starts_with?(name, web_prefix) or String.starts_with?(name, api_prefix)
      end)
    end
  end
end
