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

  @doc """
  This node and the connected nodes of its region.
  """
  def regional_nodes do
    case Portal.Config.get_env(:portal, :region, "") do
      # In dev / test we don't have a cluster / region
      "" ->
        [Node.self()]

      region ->
        nodes =
          Node.list()
          |> Enum.filter(fn node ->
            node |> Atom.to_string() |> String.contains?(region)
          end)

        [Node.self() | nodes]
    end
  end

  defmodule Changes do
    @type entity ::
            :accounts
            | :account_slugs
            | :actors
            | :client_tokens
            | :devices
            | :directories
            | :groups
            | :memberships
            | :policies
            | :policy_authorizations
            | :intune_devices
            | :iru_devices
            | :defender_devices
            | :santa_devices
            | :sentinelone_devices
            | :sophos_devices
            | :portal_sessions
            | :posture_providers
            | :resources
            | :sites
            | :x509_auth_providers

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

    @spec subscribe_to_accounts() :: :ok | {:error, term()}
    def subscribe_to_accounts do
      Portal.PubSub.subscribe(accounts_topic())
    end

    @spec broadcast(String.t(), entity(), term()) :: :ok
    def broadcast(account_id, entity, payload) do
      for topic <- [account_topic(account_id), entity_topic(account_id, entity)],
          node <- Portal.PubSub.regional_nodes() do
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, topic, payload)
      end

      :ok
    end

    @spec broadcast_account(term()) :: :ok
    def broadcast_account(payload) do
      for node <- Portal.PubSub.regional_nodes() do
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, accounts_topic(), payload)
      end

      :ok
    end

    defp account_topic(account_id), do: "account:#{account_id}"
    defp entity_topic(account_id, entity), do: "account:#{account_id}:#{entity}"

    defp accounts_topic do
      Portal.Config.get_env(:portal, :account_changes_topic, "accounts")
    end
  end
end
