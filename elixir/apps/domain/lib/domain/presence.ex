defmodule Domain.Presence do
  use Phoenix.Presence,
    otp_app: :domain,
    pubsub_server: Domain.PubSub

  alias Domain.PubSub
  alias Domain.Client
  alias Domain.Gateway
  alias Domain.Relays.Relay

  defmodule Clients do
    def connect(%Client{} = client, token_id) do
      with {:ok, _} <- __MODULE__.Account.track(client.account_id, client.id),
           {:ok, _} <- __MODULE__.Actor.track(client.actor_id, client.id, token_id) do
        :ok
      end
    end

    # Functions moved from Domain.Clients
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
        Domain.Presence.track(
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
        |> Domain.Presence.get_by_key(client_id)
      end

      def list(account_id) do
        account_id
        |> topic()
        |> Domain.Presence.list()
      end

      defp topic(account_id) do
        "presences:account_clients:" <> account_id
      end
    end

    defmodule Actor do
      def track(actor_id, client_id, token_id) do
        Domain.Presence.track(
          self(),
          topic(actor_id),
          client_id,
          %{token_id: token_id}
        )
      end

      def get(actor_id, client_id) do
        actor_id
        |> topic()
        |> Domain.Presence.get_by_key(client_id)
      end

      def list(actor_id) do
        actor_id
        |> topic()
        |> Domain.Presence.list()
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
        Domain.Presence.track(
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
        |> Domain.Presence.get_by_key(gateway_id)
      end

      def list(account_id) do
        account_id
        |> topic()
        |> Domain.Presence.list()
      end

      defp topic(account_id) do
        "presences:account_gateways:" <> account_id
      end
    end

    defmodule Site do
      def track(site_id, gateway_id, token_id) do
        Domain.Presence.track(
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
        |> Domain.Presence.list()
      end

      defp topic(site_id) do
        "presences:sites:" <> site_id
      end
    end
  end

  defmodule Relays do
    def connect(%Relay{} = relay) do
      with {:ok, _} <- track_relay(relay),
           {:ok, _} <- __MODULE__.Group.track(relay.group_id, relay.id),
           {:ok, _} <- __MODULE__.AccountOrGlobal.track(relay) do
        :ok
      end
    end

    def track(pid, topic, id, meta) do
      Domain.Presence.track(pid, topic, id, meta)
    end

    def untrack(pid, topic, id) do
      Domain.Presence.untrack(pid, topic, id)
    end

    defp track_relay(%Relay{} = relay) do
      Domain.Presence.track(self(), relay_topic(relay), relay.id, %{})
    end

    defp relay_topic(relay_or_id)
    defp relay_topic(%Relay{id: id}), do: relay_topic(id)
    defp relay_topic(relay_id), do: "presences:relays:#{relay_id}"

    # Functions moved from Domain.Relays
    @doc false
    def preload_relays_presence([relay]) do
      __MODULE__.AccountOrGlobal.get(relay)
      |> case do
        [] -> %{relay | online?: false}
        %{metas: [_ | _]} -> %{relay | online?: true}
      end
      |> List.wrap()
    end

    def preload_relays_presence(relays) do
      # Global relays
      global_relays =
        __MODULE__.Global.list()
        |> Map.keys()

      # Account-specific relays
      connected_relays =
        relays
        |> Enum.map(& &1.account_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.reduce(global_relays, fn account_id, acc ->
          connected_relays =
            account_id
            |> __MODULE__.Account.list()
            |> Map.keys()

          connected_relays ++ acc
        end)

      Enum.map(relays, fn relay ->
        %{relay | online?: relay.id in connected_relays}
      end)
    end

    def count_online_relays_for_group(group_id) do
      group_id
      |> __MODULE__.Group.list()
      |> Enum.count()
    end

    def online_relay_ids do
      global_relay_ids =
        __MODULE__.Global.list()
        |> Map.keys()

      # TODO: This needs to aggregate across all accounts if needed
      global_relay_ids
    end

    def online_relay_ids(account_id) do
      global_relay_ids =
        __MODULE__.Global.list()
        |> Map.keys()

      account_relay_ids =
        account_id
        |> __MODULE__.Account.list()
        |> Map.keys()

      global_relay_ids ++ account_relay_ids
    end

    def send_metrics do
      count = __MODULE__.Global.list() |> Enum.count()

      :telemetry.execute([:domain, :relays], %{
        online_relays_count: count
      })
    end

    def connect(%Domain.Relays.Relay{} = relay, secret, token_id) do
      with {:ok, _} <-
             Domain.Presence.track(
               self(),
               __MODULE__.Group.topic(relay.group_id),
               relay.id,
               %{
                 token_id: token_id
               }
             ),
           {:ok, _} <-
             track_relay_with_secret(relay, secret),
           {:ok, _} <-
             Domain.Presence.track(self(), "presences:relays:#{relay.id}", relay.id, %{}) do
        :ok = PubSub.Relay.subscribe(relay.id)
        :ok = PubSub.RelayGroup.subscribe(relay.group_id)
        :ok = PubSub.RelayAccount.subscribe(relay.account_id)
        :ok
      end
    end

    defp track_relay_with_secret(%Domain.Relays.Relay{account_id: nil} = relay, secret) do
      Domain.Presence.track(self(), __MODULE__.Global.topic(), relay.id, %{
        online_at: System.system_time(:second),
        secret: secret
      })
    end

    defp track_relay_with_secret(%Domain.Relays.Relay{account_id: account_id} = relay, secret) do
      Domain.Presence.track(self(), __MODULE__.Account.topic(account_id), relay.id, %{
        online_at: System.system_time(:second),
        secret: secret
      })
    end

    def all_connected_relays_for_account(account_id_or_account, except_ids \\ [])

    def all_connected_relays_for_account(%Domain.Account{} = account, except_ids) do
      all_connected_relays_for_account(account.id, except_ids)
    end

    def all_connected_relays_for_account(account_id, except_ids) do
      connected_global_relays = __MODULE__.Global.list()
      connected_account_relays = __MODULE__.Account.list(account_id)

      connected_relays = Map.merge(connected_global_relays, connected_account_relays)
      connected_relay_ids = Map.keys(connected_relays) -- except_ids

      relays = __MODULE__.DB.fetch_relays_by_ids(connected_relay_ids, account_id)

      enriched_relays =
        Enum.map(relays, fn relay ->
          %{metas: metas} = Map.get(connected_relays, relay.id)

          %{secret: stamp_secret} =
            metas
            |> Enum.sort_by(& &1.online_at, :desc)
            |> List.first()

          %{relay | stamp_secret: stamp_secret}
        end)

      {:ok, enriched_relays}
    end

    defmodule DB do
      alias Domain.Relays.Relay
      alias Domain.Safe

      def fetch_relays_by_ids(relay_ids, account_id) do
        Relay.Query.all()
        |> Relay.Query.by_ids(relay_ids)
        |> Relay.Query.global_or_by_account_id(account_id)
        |> Relay.Query.prefer_global()
        |> Safe.unscoped()
        |> Safe.all()
      end
    end

    defmodule Global do
      def topic, do: "presences:global_relays"

      def list do
        Domain.Presence.list(topic())
      end

      def subscribe do
        PubSub.subscribe(topic())
      end

      def unsubscribe do
        PubSub.unsubscribe(topic())
      end
    end

    defmodule Account do
      def track(account_id, relay_id) do
        Domain.Presence.track(
          self(),
          topic(account_id),
          relay_id,
          %{online_at: System.system_time(:second)}
        )
      end

      def get(account_id, relay_id) do
        account_id
        |> topic()
        |> Domain.Presence.get_by_key(relay_id)
      end

      def list(account_id) do
        account_id
        |> topic()
        |> Domain.Presence.list()
      end

      def subscribe(account_id) do
        account_id
        |> topic()
        |> PubSub.subscribe()
      end

      def unsubscribe(account_id) do
        account_id
        |> topic()
        |> PubSub.unsubscribe()
      end

      def topic(account_id) do
        "presences:account_relays:" <> account_id
      end
    end

    defmodule AccountOrGlobal do
      def track(%Relay{account_id: nil} = relay) do
        Domain.Presence.track(
          self(),
          Global.topic(),
          relay.id,
          %{online_at: System.system_time(:second)}
        )
      end

      def track(%Relay{account_id: account_id} = relay) do
        Account.track(account_id, relay.id)
      end

      def get(%Relay{account_id: nil, id: relay_id}) do
        Global.topic()
        |> Domain.Presence.get_by_key(relay_id)
      end

      def get(%Relay{account_id: account_id, id: relay_id}) do
        Account.get(account_id, relay_id)
      end
    end

    defmodule Group do
      def track(group_id, relay_id) do
        Domain.Presence.track(
          self(),
          topic(group_id),
          relay_id,
          %{online_at: System.system_time(:second)}
        )
      end

      def list(group_id) do
        group_id
        |> topic()
        |> Domain.Presence.list()
      end

      def subscribe(group_id) do
        group_id
        |> topic()
        |> PubSub.subscribe()
      end

      def unsubscribe(group_id) do
        group_id
        |> topic()
        |> PubSub.unsubscribe()
      end

      def topic(group_id) do
        "presences:group_relays:" <> group_id
      end
    end

    defmodule Relay do
      def subscribe(relay_id) do
        relay_id
        |> topic()
        |> PubSub.subscribe()
      end

      def unsubscribe(relay_id) do
        relay_id
        |> topic()
        |> PubSub.unsubscribe()
      end

      defp topic(relay_id) do
        "presences:relays:" <> relay_id
      end
    end

    defmodule Debouncer do
      require Logger

      @moduledoc """
      Encapsulates the logic for debouncing relay presence leave events to prevent
      sending spurious disconnects to clients/gateways when a relay experiences
      transient disconnections to the portal.
      """

      def cache_stamp_secrets(socket, relays) do
        stamp_secrets = Map.get(socket.assigns, :stamp_secrets, %{})

        stamp_secrets =
          Enum.reduce(relays, stamp_secrets, fn relay, acc ->
            Map.put(acc, relay.id, relay.stamp_secret)
          end)

        Phoenix.Socket.assign(socket, :stamp_secrets, stamp_secrets)
      end

      # Removes reconnected relays from pending leaves:
      # - If the stamp secret hasn't changed, we need to cancel the pending leave
      # - If it has, we need to disconnect from the relay immediately
      def cancel_leaves_or_disconnect_immediately(socket, joined_ids, account_id) do
        {:ok, connected_relays} =
          Domain.Presence.Relays.all_connected_relays_for_account(account_id)

        joined_stamp_secrets =
          connected_relays
          |> Enum.filter(fn relay -> relay.id in joined_ids end)
          |> Enum.reduce(%{}, fn relay, acc -> Map.put(acc, relay.id, relay.stamp_secret) end)

        pending_leaves = Map.get(socket.assigns, :pending_leaves, %{})

        # Immediately disconnect from relays where stamp secret has changed
        disconnected_ids =
          Enum.reduce(pending_leaves, [], fn {relay_id, stamp_secret}, acc ->
            if Map.get(joined_stamp_secrets, relay_id) != stamp_secret do
              [relay_id | acc]
            else
              acc
            end
          end)

        # Remove any reconnected relays from pending leaves
        pending_leaves =
          pending_leaves
          |> Map.reject(fn {relay_id, _stamp_secret} ->
            relay_id in joined_ids
          end)

        socket = Phoenix.Socket.assign(socket, :pending_leaves, pending_leaves)

        {socket, disconnected_ids}
      end

      def queue_leave(pid, socket, relay_id, payload) do
        stamp_secrets = Map.get(socket.assigns, :stamp_secrets, %{})
        stamp_secret = Map.get(stamp_secrets, relay_id)
        Process.send_after(pid, {:push_leave, relay_id, stamp_secret, payload}, timeout())
        pending_leaves = Map.get(socket.assigns, :pending_leaves, %{})

        Phoenix.Socket.assign(
          socket,
          :pending_leaves,
          Map.put(pending_leaves, relay_id, stamp_secret)
        )
      end

      def handle_leave(socket, relay_id, stamp_secret, payload, push_fn) do
        pending_leaves = Map.get(socket.assigns, :pending_leaves, %{})

        if Map.get(pending_leaves, relay_id) == stamp_secret do
          push_fn.(socket, "relays_presence", payload)

          Phoenix.Socket.assign(socket, :pending_leaves, Map.delete(pending_leaves, relay_id))
        else
          socket
        end
      end

      def timeout do
        Application.fetch_env!(:api, :relays_presence_debounce_timeout_ms)
      end
    end
  end
end
