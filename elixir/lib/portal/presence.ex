defmodule Portal.Presence do
  use Phoenix.Presence,
    otp_app: :portal,
    pubsub_server: Portal.PubSub

  alias Portal.PubSub
  alias Portal.Device

  defmodule Devices do
    @moduledoc """
    Presence for everything running Firezone in an account.

    Clients and gateways used to be tracked apart, on two account topics whose
    metadata had grown into two different shapes. They are one tracker now:
    one account topic, and one meta shape built in one place, so a reader that
    does not care which kind it is looking at does not have to know.
    """
    alias Portal.Device

    @doc """
    What every device puts in its presence, whichever kind it is.

    The same keys either way, `nil` where a kind has no answer, so a reader
    never has to know which one it is holding.
    """
    def session_meta(%Device{} = device, extra \\ %{}) do
      %{
        type: device.type,
        name: device.name,
        actor_id: device.actor_id,
        ipv4: device.ipv4 && device.ipv4.address,
        ipv6: device.ipv6 && device.ipv6.address,
        public_key: device.public_key,
        psk_base: device.psk_base,
        site_id: device.site_id,
        version: device.last_seen_version,
        user_agent: device.last_seen_user_agent,
        remote_ip: device.last_seen_remote_ip,
        remote_ip_location_lat: device.last_seen_remote_ip_location_lat,
        remote_ip_location_lon: device.last_seen_remote_ip_location_lon,
        attested?: device.attested?
      }
      |> Map.merge(extra)
    end

    def connect(%Device{} = device, token_id, session_meta \\ %{}) do
      __MODULE__.Account.track(device, Map.put(session_meta, :token_id, token_id))
    end

    @doc """
    Fills in `online?` for a list holding either kind of device.
    """
    def preload_presence([device]) do
      case __MODULE__.Account.get(device.account_id, device.id) do
        [] -> [%{device | online?: false}]
        %{metas: [_ | _]} -> [%{device | online?: true}]
      end
    end

    def preload_presence(devices) do
      online =
        devices
        |> Enum.map(& &1.account_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.flat_map(&online_ids/1)
        |> MapSet.new()

      Enum.map(devices, &%{&1 | online?: MapSet.member?(online, &1.id)})
    end

    @doc "The ids of every device of either kind connected to an account."
    def online_ids(account_id) do
      account_id
      |> __MODULE__.Account.list()
      |> Map.keys()
    end

    @doc "The ids of the connected devices of one kind."
    def online_ids(account_id, type) do
      account_id
      |> __MODULE__.Account.list()
      |> Enum.filter(fn {_id, %{metas: [meta | _]}} -> meta.type == type end)
      |> Enum.map(&elem(&1, 0))
    end

    @doc "How many gateways are connected to each site, keyed by site id."
    def online_gateway_counts(account_id) do
      account_id
      |> __MODULE__.Account.list()
      |> Enum.reduce(%{}, fn
        {_id, %{metas: [%{type: :gateway, site_id: site_id} | _]}}, acc ->
          Map.update(acc, site_id, 1, &(&1 + 1))

        _client, acc ->
          acc
      end)
    end

    @doc "The ids of the sites with at least one gateway connected."
    def online_site_ids(account_id) do
      account_id |> online_gateway_counts() |> Map.keys() |> MapSet.new()
    end

    @doc "The ids of the tokens that a connected device of one actor is using."
    def online_token_ids(account_id, actor_id) do
      account_id
      |> __MODULE__.Account.list()
      |> Enum.flat_map(fn {_id, %{metas: metas}} ->
        for %{actor_id: ^actor_id, token_id: token_id} <- metas, do: token_id
      end)
    end

    @doc "Whether a presence diff carries a device of the actor."
    def diff_includes_actor?(%{joins: joins, leaves: leaves}, actor_id) do
      [joins, leaves]
      |> Enum.flat_map(&Map.values/1)
      |> Enum.any?(fn %{metas: metas} -> Enum.any?(metas, &(Map.get(&1, :actor_id) == actor_id)) end)
    end

    def fetch_gateway(account_id, gateway_id) do
      case __MODULE__.Account.get(account_id, gateway_id) do
        %{metas: [%{type: :gateway} = meta | _]} ->
          {:ok, from_meta(gateway_id, account_id, meta)}

        _offline_or_not_a_gateway ->
          {:error, :offline}
      end
    end

    def all_connected_gateways(account_id) do
      account_id
      |> __MODULE__.Account.list()
      |> Enum.flat_map(fn
        {id, %{metas: [%{type: :gateway} = meta | _]}} -> [from_meta(id, account_id, meta)]
        _other_kind -> []
      end)
    end

    defp from_meta(id, account_id, meta) do
      %Device{
        id: id,
        account_id: account_id,
        type: meta.type,
        site_id: meta.site_id,
        psk_base: meta.psk_base,
        online?: true,
        public_key: meta.public_key,
        last_seen_version: meta.version,
        last_seen_remote_ip: normalize_ip(meta.remote_ip),
        last_seen_remote_ip_location_lat: meta.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: meta.remote_ip_location_lon
      }
    end

    defp normalize_ip(%Postgrex.INET{} = inet), do: inet
    defp normalize_ip(tuple) when is_tuple(tuple), do: %Postgrex.INET{address: tuple}
    defp normalize_ip(nil), do: nil

    @doc """
    Preloads `online?` for client tokens.

    A token is online when any device is connected using it.
    """
    def preload_client_tokens_presence(tokens) when is_list(tokens) do
      online_token_ids =
        tokens
        |> Enum.map(&{&1.account_id, &1.actor_id})
        |> Enum.uniq()
        |> Enum.flat_map(fn {account_id, actor_id} -> online_token_ids(account_id, actor_id) end)
        |> MapSet.new()

      Enum.map(tokens, &%{&1 | online?: MapSet.member?(online_token_ids, &1.id)})
    end

    defmodule Account do
      alias Portal.Presence.Devices

      def track(device, extra \\ %{}) do
        meta =
          device
          |> Devices.session_meta(extra)
          |> Map.put(:online_at, System.system_time(:second))

        case Portal.Presence.track(self(), topic(device.account_id), device.id, meta) do
          {:ok, _} ->
            :ok

          {:error, {:already_tracked, _, _, _}} ->
            Portal.Presence.update(self(), topic(device.account_id), device.id, meta)
            :ok
        end
      end

      def subscribe(account_id), do: account_id |> topic() |> PubSub.subscribe()

      def get(account_id, device_id) do
        account_id |> topic() |> Portal.Presence.get_by_key(device_id)
      end

      def list(account_id), do: account_id |> topic() |> Portal.Presence.list()

      def find_by_ipv4(account_id, ipv4_tuple) when is_tuple(ipv4_tuple) do
        find_by_address(account_id, :ipv4, ipv4_tuple)
      end

      def find_by_ipv6(account_id, ipv6_tuple) when is_tuple(ipv6_tuple) do
        find_by_address(account_id, :ipv6, ipv6_tuple)
      end

      # Both kinds share this topic and both hold tunnel addresses, so the
      # lookup says which kind it wants rather than trusting the address to
      # belong to only one.
      defp find_by_address(account_id, key, address) do
        account_id
        |> list()
        |> Enum.find_value(fn {device_id, %{metas: [meta | _]}} ->
          if meta.type == :client and Map.get(meta, key) == address, do: {device_id, meta}
        end)
      end

      def topic(account_id), do: "presences:account_devices:" <> account_id
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

    def subscribe(actor_id) do
      actor_id
      |> topic()
      |> PubSub.subscribe()
    end

    def unsubscribe(actor_id) do
      actor_id
      |> topic()
      |> PubSub.unsubscribe()
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

  defmodule Relays do
    @moduledoc """
    Presence tracking for relays. Relays are ephemeral and only exist while connected.
    They are identified by their id (a UUID derived from the stamp_secret).
    """

    alias Portal.Relay

    def send_metrics do
      count = list() |> Enum.count()

      :telemetry.execute([:portal, :relays], %{
        online_relays_count: count
      })
    end

    def connect(%Relay{} = relay) do
      # Kill any existing connections with the same id to handle
      # reconnection scenarios where the load balancer killed the old connection
      # but the backend hasn't learned about it yet (heartbeat timeout pending)
      disconnect_by_id(relay.id)

      with {:ok, _} <-
             Portal.Presence.track(self(), topic(), relay.id, %{
               stamp_secret: relay.stamp_secret,
               ipv4: relay.ipv4,
               ipv6: relay.ipv6,
               port: relay.port,
               lat: relay.lat,
               lon: relay.lon,
               turn_account_validation: relay.turn_account_validation == true
             }) do
        :ok
      end
    end

    defp disconnect_by_id(id) do
      topic = topic()

      # Phoenix.Tracker.get_by_key returns [{pid, meta}] for each presence
      Phoenix.Tracker.get_by_key(Portal.Presence, topic, id)
      |> Enum.each(fn {pid, _meta} ->
        if pid != self() do
          Process.exit(pid, :shutdown)
        end
      end)
    end

    @doc """
    Disconnects a relay from presence.
    """
    def disconnect(%Relay{id: id}) do
      Portal.Presence.untrack(self(), topic(), id)
    end

    def all_connected_relays(except_ids \\ []) do
      connected_relays = list()

      relays =
        connected_relays
        |> Enum.reject(fn {id, _} -> id in except_ids end)
        |> Enum.map(fn {id, %{metas: [meta | _]}} ->
          %Relay{
            id: id,
            stamp_secret: meta.stamp_secret,
            ipv4: meta.ipv4,
            ipv6: meta.ipv6,
            port: meta.port,
            lat: Map.get(meta, :lat),
            lon: Map.get(meta, :lon),
            turn_account_validation: Map.get(meta, :turn_account_validation, false)
          }
        end)

      {:ok, relays}
    end

    def topic do
      Portal.Config.get_env(:portal, :relay_presence_topic, "presences:relays")
    end

    def list, do: Portal.Presence.list(topic())
    def subscribe, do: PubSub.subscribe(topic())
    def unsubscribe, do: PubSub.unsubscribe(topic())
  end
end
