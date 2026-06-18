defmodule Portal.PubSub do
  @moduledoc """
  A wrapper around Phoenix.PubSub that allows us not to spread the knowledge of the process name
  across applications.
  """
  use Supervisor

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
    @type entity ::
            :accounts
            | :actors
            | :client_tokens
            | :devices
            | :directories
            | :groups
            | :memberships
            | :policies
            | :policy_authorizations
            | :portal_sessions
            | :resources
            | :sites
            | :static_device_pool_members

    @spec subscribe(String.t()) :: :ok | {:error, term()}
    def subscribe(account_id) do
      account_id
      |> account_topic()
      |> Portal.PubSub.subscribe()
    end

    @spec subscribe(String.t(), entity()) :: :ok | {:error, term()}
    def subscribe(account_id, entity) do
      account_id
      |> entity_topic(entity)
      |> Portal.PubSub.subscribe()
    end

    @spec broadcast(String.t(), entity(), term()) :: :ok
    def broadcast(account_id, entity, payload) do
      region = Portal.Config.get_env(:portal, :region, "")

      for topic <- [account_topic(account_id), entity_topic(account_id, entity)],
          node <- target_nodes(region) do
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, topic, payload)
      end

      :ok
    end

    defp account_topic(account_id), do: "account:#{account_id}"
    defp entity_topic(account_id, entity), do: "account:#{account_id}:#{entity}"

    # In dev / test region we don't have a cluster / region; send to self
    defp target_nodes(""), do: [Node.self()]

    defp target_nodes(region) do
      nodes =
        Node.list()
        |> Enum.filter(fn node ->
          node |> Atom.to_string() |> String.contains?(region)
        end)

      [Node.self() | nodes]
    end
  end
end
