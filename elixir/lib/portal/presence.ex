defmodule Portal.Presence do
  use Phoenix.Presence,
    otp_app: :portal,
    pubsub_server: Portal.PubSub

  alias Portal.PubSub
  alias Portal.Client
  alias Portal.Gateway

  defmodule Clients do
    def connect(%Client{} = client, token_id) do
      with {:ok, _} <- __MODULE__.Account.track(client.account_id, client.id),
           {:ok, _} <- __MODULE__.Actor.track(client.actor_id, client.id, token_id) do
        :ok
      end
    end

    # Functions moved from Portal.Clients
    @doc false
    def preload_clients_presence([client]) do
      __MODULE__.Account.get(client.account_id, client.id)
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
      |> __MODULE__.Account.list()
      |> Map.keys()
    end

    defmodule Account do
      def track(account_id, client_id) do
        Portal.Presence.track(
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
        |> Portal.Presence.get_by_key(client_id)
      end

      def list(account_id) do
        account_id
        |> topic()
        |> Portal.Presence.list()
      end

      defp topic(account_id) do
        "presences:account_clients:" <> account_id
      end
    end

    defmodule Actor do
      def track(actor_id, client_id, token_id) do
        Portal.Presence.track(
          self(),
          topic(actor_id),
          client_id,
          %{token_id: token_id}
        )
      end

      def get(actor_id, client_id) do
        actor_id
        |> topic()
        |> Portal.Presence.get_by_key(client_id)
      end

      def list(actor_id) do
        actor_id
        |> topic()
        |> Portal.Presence.list()
      end

      def subscribe(actor_id) do
        actor_id
        |> topic()
        |> PubSub.subscribe()
      end

      def online_token_ids(actor_id) do
        actor_id
        |> list()
        |> Enum.flat_map(fn {_client_id, %{metas: metas}} ->
          Enum.map(metas, & &1.token_id)
        end)
      end

      defp topic(actor_id) do
        "presences:actor_clients:" <> actor_id
      end
    end

    @doc """
    Preloads the online? virtual field for client tokens based on actor presence.
    A token is considered online if any client is connected using that token.
    """
    def preload_client_tokens_presence(tokens) when is_list(tokens) do
      # Group tokens by actor_id to batch presence lookups
      online_token_ids =
        tokens
        |> Enum.map(& &1.actor_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.flat_map(&Actor.online_token_ids/1)
        |> MapSet.new()

      Enum.map(tokens, fn token ->
        %{token | online?: MapSet.member?(online_token_ids, token.id)}
      end)
    end
  end

  defmodule PortalSessions do
    def track(actor_id, session_id) do
      Portal.Presence.track(
        self(),
        topic(actor_id),
        session_id,
        %{}
      )
    end

    def online_session_ids(actor_id) do
      actor_id
      |> topic()
      |> Portal.Presence.list()
      |> Map.keys()
    end

    defp topic(actor_id) do
      "presences:portal_sessions:" <> actor_id
    end

    @doc """
    Preloads the online? virtual field for portal sessions based on presence.
    A session is considered online if it's currently connected to a LiveView.
    """
    def preload_portal_sessions_presence(sessions) when is_list(sessions) do
      online_session_ids =
        sessions
        |> Enum.map(& &1.actor_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.flat_map(&online_session_ids/1)
        |> MapSet.new()

      Enum.map(sessions, fn session ->
        %{session | online?: MapSet.member?(online_session_ids, session.id)}
      end)
    end
  end

  defmodule Gateways do
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
        Portal.Presence.track(
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
        |> Portal.Presence.get_by_key(gateway_id)
      end

      def list(account_id) do
        account_id
        |> topic()
        |> Portal.Presence.list()
      end

      defp topic(account_id) do
        "presences:account_gateways:" <> account_id
      end
    end

    defmodule Site do
      def track(site_id, gateway_id, token_id) do
        Portal.Presence.track(
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
        |> Portal.Presence.list()
      end

      defp topic(site_id) do
        "presences:sites:" <> site_id
      end
    end
  end

  defmodule Relays do
    def track(pid, topic, id, meta) do
      Portal.Presence.track(pid, topic, id, meta)
    end

    def untrack(pid, topic, id) do
      Portal.Presence.untrack(pid, topic, id)
    end

    # Functions moved from Portal.Relays
    @doc false
    def preload_relays_presence([relay]) do
      __MODULE__.Global.topic()
      |> Portal.Presence.get_by_key(relay.id)
      |> case do
        [] -> %{relay | online?: false}
        %{metas: [_ | _]} -> %{relay | online?: true}
      end
      |> List.wrap()
    end

    def preload_relays_presence(relays) do
      # Only global relays now
      connected_relays =
        __MODULE__.Global.list()
        |> Map.keys()

      Enum.map(relays, fn relay ->
        %{relay | online?: relay.id in connected_relays}
      end)
    end

    def online_relay_ids do
      __MODULE__.Global.list()
      |> Map.keys()
    end

    def send_metrics do
      count = __MODULE__.Global.list() |> Enum.count()

      :telemetry.execute([:portal, :relays], %{
        online_relays_count: count
      })
    end

    def connect(%Portal.Relay{} = relay, secret, token_id) do
      # Kill any existing connections with the same stamp_secret to handle
      # reconnection scenarios where the load balancer killed the old connection
      # but the backend hasn't learned about it yet (heartbeat timeout pending)
      disconnect_by_stamp_secret(secret)

      with {:ok, _} <-
             Portal.Presence.track(self(), __MODULE__.Global.topic(), relay.id, %{
               online_at: System.system_time(:second),
               secret: secret,
               token_id: token_id,
               ipv4: relay.ipv4,
               ipv6: relay.ipv6,
               port: relay.port,
               last_seen_remote_ip_location_lat: relay.last_seen_remote_ip_location_lat,
               last_seen_remote_ip_location_lon: relay.last_seen_remote_ip_location_lon
             }) do
        :ok = PubSub.Relay.subscribe(relay.id)
        :ok
      end
    end

    defp disconnect_by_stamp_secret(secret) do
      topic = __MODULE__.Global.topic()

      # Get all connected relays and find any with matching stamp_secret
      topic
      |> Portal.Presence.list()
      |> Enum.each(fn {relay_id, _} ->
        # Phoenix.Tracker.get_by_key returns [{pid, meta}] for each presence
        Phoenix.Tracker.get_by_key(Portal.Presence, topic, relay_id)
        |> Enum.each(fn {pid, meta} ->
          if meta.secret == secret and pid != self() do
            Process.exit(pid, :shutdown)
          end
        end)
      end)
    end

    def all_connected_relays(except_ids \\ []) do
      connected_relays = __MODULE__.Global.list()

      relays =
        connected_relays
        |> Enum.reject(fn {id, _} -> id in except_ids end)
        |> Enum.map(fn {id, %{metas: metas}} ->
          meta =
            metas
            |> Enum.sort_by(& &1.online_at, :desc)
            |> List.first()

          %Portal.Relay{
            id: id,
            ipv4: meta.ipv4,
            ipv6: meta.ipv6,
            port: meta.port,
            stamp_secret: meta.secret,
            last_seen_remote_ip_location_lat: Map.get(meta, :last_seen_remote_ip_location_lat),
            last_seen_remote_ip_location_lon: Map.get(meta, :last_seen_remote_ip_location_lon)
          }
        end)

      {:ok, relays}
    end

    defmodule Global do
      def topic do
        Portal.Config.get_env(:portal, :relay_presence_topic, "presences:global_relays")
      end

      def list do
        Portal.Presence.list(topic())
      end

      def subscribe do
        PubSub.subscribe(topic())
      end

      def unsubscribe do
        PubSub.unsubscribe(topic())
      end
    end
  end
end
