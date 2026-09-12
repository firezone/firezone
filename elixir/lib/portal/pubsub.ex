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
            | :posture_providers
            | :resources
            | :sites
            | :static_device_pool_members
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
      region = Portal.Config.get_env(:portal, :region, "")

      for topic <- [account_topic(account_id), entity_topic(account_id, entity)],
          node <- target_nodes(region) do
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, topic, payload)
      end

      :ok
    end

    @spec broadcast_account(term()) :: :ok
    def broadcast_account(payload) do
      region = Portal.Config.get_env(:portal, :region, "")

      for node <- target_nodes(region) do
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, accounts_topic(), payload)
      end

      :ok
    end

    @type posture_key :: {:mdm_device_id | :serial | :entra_device_id, String.t()}

    @doc "Listens for changes to posture provider rows that carry this identifier."
    @spec subscribe_posture_rows(String.t(), posture_key()) :: :ok | {:error, term()}
    def subscribe_posture_rows(account_id, key) do
      Portal.PubSub.subscribe(posture_rows_topic(account_id, key))
    end

    @spec unsubscribe_posture_rows(String.t(), posture_key()) :: :ok
    def unsubscribe_posture_rows(account_id, key) do
      Portal.PubSub.unsubscribe(posture_rows_topic(account_id, key))
    end

    # Published per identifier, never account-wide: a sync rewrites every row
    # it reports, and only the channel of the device a row describes needs it.
    @spec broadcast_posture_rows(String.t(), [posture_key()], term()) :: :ok
    def broadcast_posture_rows(account_id, keys, payload) do
      region = Portal.Config.get_env(:portal, :region, "")

      for key <- keys, node <- target_nodes(region) do
        topic = posture_rows_topic(account_id, key)
        Phoenix.PubSub.direct_broadcast!(node, Portal.PubSub, topic, payload)
      end

      :ok
    end

    defp account_topic(account_id), do: "account:#{account_id}"
    defp entity_topic(account_id, entity), do: "account:#{account_id}:#{entity}"

    defp posture_rows_topic(account_id, {kind, value}) do
      "account:#{account_id}:posture_rows:#{kind}:#{value}"
    end
    defp accounts_topic do
      Portal.Config.get_env(:portal, :account_changes_topic, "accounts")
    end

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
