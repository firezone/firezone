defmodule API.Client.Channel do
  use API, :channel
  alias API.Client.Views

  alias Domain.{
    Accounts,
    Clients,
    Cache,
    Changes.Change,
    Actors,
    PubSub,
    Resources,
    Flows,
    Gateways,
    Relays,
    Policies,
    Flows
  }

  alias Domain.Relays.Presence.Debouncer
  require Logger
  require OpenTelemetry.Tracer

  # For time-based policy conditions, we need to determine whether we still have access
  # If not, we need to send resource_deleted so that if it's added back later, the client's
  # connlib state will be cleaned up so it can request a new connection.
  @recompute_authorized_resources_every :timer.minutes(1)

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def join("client", _payload, socket) do
    send(self(), :after_join)

    {:ok, socket}
  end

  @impl true

  # Called immediately after the client joins the channel
  def handle_info(:after_join, socket) do
    # Schedule reassessing allowed resources
    Process.send_after(
      self(),
      :recompute_authorized_resources,
      @recompute_authorized_resources_every
    )

    # Get initial list of authorized resources, hydrating the cache
    {:ok, resources, [], cache} =
      Cache.Client.recompute_connectable_resources(nil, socket.assigns.client)

    # Initialize relays
    {:ok, relays} = select_relays(socket)
    :ok = Enum.each(relays, &Relays.subscribe_to_relay_presence/1)
    :ok = maybe_subscribe_for_relays_presence(relays, socket)

    # Initialize debouncer for flappy relays
    socket = Debouncer.cache_stamp_secrets(socket, relays)

    # Track client's presence
    :ok = Clients.Presence.connect(socket.assigns.client, socket.assigns.subject.token_id)

    # Subscribe to all account updates
    :ok = PubSub.Account.subscribe(socket.assigns.client.account_id)

    # Delete any stale flows for resources we may not have access to anymore based on policy conditions
    Flows.delete_stale_flows_on_connect(
      socket.assigns.client,
      Enum.map(resources, &Ecto.UUID.load!(&1.id))
    )

    push(socket, "init", %{
      resources: Views.Resource.render_many(resources),
      relays:
        Views.Relay.render_many(
          relays,
          socket.assigns.client.public_key,
          socket.assigns.subject.expires_at
        ),
      interface:
        Views.Interface.render(%{
          socket.assigns.client
          | account: socket.assigns.subject.account
        })
    })

    {:noreply, assign(socket, cache: cache)}
  end

  # Called to actually push relays_presence with a disconnected relay to the client
  def handle_info({:push_leave, relay_id, stamp_secret, payload}, socket) do
    {:noreply, Debouncer.handle_leave(socket, relay_id, stamp_secret, payload, &push/3)}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  def handle_info(%Change{lsn: lsn} = change, socket) do
    last_lsn = Map.get(socket.assigns, :last_lsn, 0)

    if lsn <= last_lsn do
      Logger.warning("Out of order or duplicate change received; ignoring",
        change: change,
        last_lsn: last_lsn
      )

      {:noreply, socket}
    else
      socket = assign(socket, last_lsn: lsn)

      handle_change(change, socket)
    end
  end

  ####################################
  ##### Reacting to timed events #####
  ####################################

  # This is needed to keep the client's resource list up to date for time-based policy conditions
  # since we will not receive any change messages to react to when time-based policies expire.
  def handle_info(:recompute_authorized_resources, socket) do
    Process.send_after(
      self(),
      :recompute_authorized_resources,
      @recompute_authorized_resources_every
    )

    {:ok, added_resources, removed_ids, cache} =
      Cache.Client.recompute_connectable_resources(socket.assigns.cache, socket.assigns.client)

    for resource_id <- removed_ids do
      push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      push(socket, "resource_created_or_updated", Views.Resource.render(resource))
    end

    {:noreply, assign(socket, cache: cache)}
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:relays:" <> relay_id,
          payload: %{leaves: leaves}
        },
        socket
      ) do
    if Map.has_key?(leaves, relay_id) do
      :ok = Relays.unsubscribe_from_relay_presence(relay_id)

      {:ok, relays} = select_relays(socket, [relay_id])
      :ok = maybe_subscribe_for_relays_presence(relays, socket)

      :ok =
        Enum.each(relays, fn relay ->
          # TODO: Why are we unsubscribing and subscribing again?
          :ok = Relays.unsubscribe_from_relay_presence(relay)
          :ok = Relays.subscribe_to_relay_presence(relay)
        end)

      payload = %{
        disconnected_ids: [relay_id],
        connected:
          Views.Relay.render_many(
            relays,
            socket.assigns.client.public_key,
            socket.assigns.subject.expires_at
          )
      }

      {:noreply, Debouncer.queue_leave(self(), socket, relay_id, payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:" <> _,
          payload: %{joins: joins}
        },
        socket
      ) do
    if Enum.count(joins) > 0 do
      {:ok, relays} = select_relays(socket)

      if length(relays) > 0 do
        :ok = Relays.unsubscribe_from_relays_presence_in_account(socket.assigns.subject.account)

        :ok =
          Enum.each(relays, fn relay ->
            # TODO: Why are we unsubscribing and subscribing again?
            :ok = Relays.unsubscribe_from_relay_presence(relay)
            :ok = Relays.subscribe_to_relay_presence(relay)
          end)

        # Cache new stamp secrets
        socket = Debouncer.cache_stamp_secrets(socket, relays)

        # If a relay reconnects with a different stamp_secret, disconnect them immediately
        joined_ids = Map.keys(joins)

        {socket, disconnected_ids} =
          Debouncer.cancel_leaves_or_disconnect_immediately(
            socket,
            joined_ids,
            socket.assigns.client.account_id
          )

        {:ok, relays} = select_relays(socket)

        push(socket, "relays_presence", %{
          disconnected_ids: disconnected_ids,
          connected:
            Views.Relay.render_many(
              relays,
              socket.assigns.client.public_key,
              socket.assigns.subject.expires_at
            )
        })

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  #############################################################
  ##### Forwarding replies from the gateway to the client #####
  #############################################################

  # This the list of ICE candidates gathered by the gateway and relayed to the client
  def handle_info(
        {{:ice_candidates, client_id}, gateway_id, candidates},
        %{assigns: %{client: %{id: id}}} = socket
      )
      when client_id == id do
    push(socket, "ice_candidates", %{
      gateway_id: gateway_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:invalidate_ice_candidates, client_id}, gateway_id, candidates},
        %{assigns: %{client: %{id: id}}} = socket
      )
      when client_id == id do
    push(socket, "invalidate_ice_candidates", %{
      gateway_id: gateway_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  # This message is sent by the gateway when it is ready to accept the connection from the client
  def handle_info(
        {:connect, socket_ref, rid_bytes, gateway_public_key, payload},
        socket
      ) do
    reply(
      socket_ref,
      {:ok,
       %{
         resource_id: Ecto.UUID.load!(rid_bytes),
         persistent_keepalive: 25,
         gateway_public_key: gateway_public_key,
         gateway_payload: payload
       }}
    )

    {:noreply, socket}
  end

  def handle_info(
        {:connect, _socket_ref, rid_bytes, gateway_group_id, gateway_id, gateway_public_key,
         gateway_ipv4, gateway_ipv6, preshared_key, ice_credentials},
        socket
      ) do
    reply_payload = %{
      resource_id: Ecto.UUID.load!(rid_bytes),
      preshared_key: preshared_key,
      client_ice_credentials: ice_credentials.client,
      gateway_group_id: gateway_group_id,
      gateway_id: gateway_id,
      gateway_public_key: gateway_public_key,
      gateway_ipv4: gateway_ipv4,
      gateway_ipv6: gateway_ipv6,
      gateway_ice_credentials: ice_credentials.gateway
    }

    push(socket, "flow_created", reply_payload)

    {:noreply, socket}
  end

  # Catch-all for messages we don't handle
  def handle_info(_message, socket), do: {:noreply, socket}

  ####################################
  ##### Client-initiated actions #####
  ####################################

  # This message is sent to the client to request a network flow with a gateway that can serve given resource.
  #
  # `connected_gateway_ids` is used to indicate that the client is already connected to some of the gateways,
  # so the gateway can be reused by multiplexing the connection.
  def handle_in(
        "create_flow",
        %{
          "resource_id" => resource_id,
          "connected_gateway_ids" => connected_gateway_ids
        },
        socket
      ) do
    with {:ok, resource, membership_id, policy_id, expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateways} when gateways != [] <-
           Gateways.all_compatible_gateways_for_client_and_resource(
             socket.assigns.client,
             resource,
             socket.assigns.subject
           ) do
      location = {
        socket.assigns.client.last_seen_remote_ip_location_lat,
        socket.assigns.client.last_seen_remote_ip_location_lon
      }

      gateway = Gateways.load_balance_gateways(location, gateways, connected_gateway_ids)

      # TODO: Optimization
      # Move this to a Task.start that completes after broadcasting authorize_flow
      {:ok, flow} =
        Flows.create_flow(
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      preshared_key = generate_preshared_key(socket.assigns.client, gateway)
      ice_credentials = generate_ice_credentials(socket.assigns.client, gateway)

      :ok =
        PubSub.Account.broadcast(
          socket.assigns.client.account_id,
          {{:authorize_flow, gateway.id}, {self(), socket_ref(socket)},
           %{
             client: socket.assigns.client,
             resource: resource,
             flow_id: flow.id,
             authorization_expires_at: expires_at,
             ice_credentials: ice_credentials,
             preshared_key: preshared_key,
             subject: socket.assigns.subject
           }}
        )

      {:noreply, socket}
    else
      {:error, :not_found} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :not_found
        })

        {:noreply, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :forbidden,
          violated_properties: violated_properties
        })

        {:noreply, socket}

      {:ok, []} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :offline
        })

        {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  # The client sends it's message to list relays and select a gateway whenever it wants
  # to connect to a resource.
  #
  # Client can send `connected_gateway_ids` to indicate that it is already connected to
  # some of the gateways and can multiplex the connections.
  @impl true
  def handle_in("prepare_connection", %{"resource_id" => resource_id} = attrs, socket) do
    connected_gateway_ids = Map.get(attrs, "connected_gateway_ids", [])

    # TODO: Optimization
    # Gateway selection and flow authorization shouldn't need to hit the DB
    with {:ok, resource, _membership_id, _policy_id, _expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateways} when gateways != [] <-
           Gateways.all_compatible_gateways_for_client_and_resource(
             socket.assigns.client,
             resource,
             socket.assigns.subject
           ) do
      location = {
        socket.assigns.client.last_seen_remote_ip_location_lat,
        socket.assigns.client.last_seen_remote_ip_location_lon
      }

      gateway = Gateways.load_balance_gateways(location, gateways, connected_gateway_ids)

      reply =
        {:ok,
         %{
           resource_id: resource_id,
           gateway_group_id: gateway.group_id,
           gateway_id: gateway.id,
           gateway_remote_ip: gateway.last_seen_remote_ip
         }}

      {:reply, reply, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:ok, []} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}
    end
  end

  # DEPRECATED IN 1.4
  # This message is sent by the client when it already has connection to a gateway,
  # but wants to multiplex the connection to access a new resource
  def handle_in(
        "reuse_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "payload" => payload
        },
        socket
      ) do
    with {:ok, resource, membership_id, policy_id, expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject, preload: :online?),
         %Cache.Cacheable.GatewayGroup{} <-
           Enum.find(resource.gateway_groups, {:error, :not_found}, fn g ->
             g.id == Ecto.UUID.dump!(gateway.group_id)
           end),
         true <- gateway.online? do
      # TODO: Optimization
      {:ok, flow} =
        Flows.create_flow(
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      :ok =
        PubSub.Account.broadcast(
          socket.assigns.client.account_id,
          {{:allow_access, gateway.id}, {self(), socket_ref(socket)},
           %{
             client: socket.assigns.client,
             resource: resource,
             flow_id: flow.id,
             authorization_expires_at: expires_at,
             client_payload: payload
           }}
        )

      {:noreply, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  # DEPRECATED IN 1.4
  # This message is sent by the client when it wants to connect to a new gateway
  # to access a resource
  def handle_in(
        "request_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "client_payload" => client_payload,
          "client_preshared_key" => preshared_key
        },
        socket
      ) do
    # Flow authorization can happen out-of-band since we just authorized the resource above
    with {:ok, resource, membership_id, policy_id, expires_at} <-
           Cache.Client.authorize_resource(
             socket.assigns.cache,
             socket.assigns.client,
             resource_id,
             socket.assigns.subject
           ),
         {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject, preload: :online?),
         %Cache.Cacheable.GatewayGroup{} <-
           Enum.find(resource.gateway_groups, {:error, :not_found}, fn g ->
             g.id == Ecto.UUID.dump!(gateway.group_id)
           end),
         true <- gateway.online? do
      # TODO: Optimization
      {:ok, flow} =
        Flows.create_flow(
          socket.assigns.client,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          socket.assigns.subject,
          expires_at
        )

      :ok =
        PubSub.Account.broadcast(
          socket.assigns.client.account_id,
          {{:request_connection, gateway.id}, {self(), socket_ref(socket)},
           %{
             client: socket.assigns.client,
             resource: resource,
             flow_id: flow.id,
             authorization_expires_at: expires_at,
             client_payload: client_payload,
             client_preshared_key: preshared_key
           }}
        )

      {:noreply, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  # The client pushes it's ICE candidates list and the list of gateways that need to receive it
  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    :ok =
      Enum.each(gateway_ids, fn gateway_id ->
        PubSub.Account.broadcast(
          socket.assigns.client.account_id,
          {{:ice_candidates, gateway_id}, socket.assigns.client.id, candidates}
        )
      end)

    {:noreply, socket}
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    :ok =
      Enum.each(gateway_ids, fn gateway_id ->
        PubSub.Account.broadcast(
          socket.assigns.client.account_id,
          {{:invalidate_ice_candidates, gateway_id}, socket.assigns.client.id, candidates}
        )
      end)

    {:noreply, socket}
  end

  # Catch-all for unknown messages
  def handle_in(message, payload, socket) do
    Logger.error("Unknown client message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp select_relays(socket, except_ids \\ []) do
    {:ok, relays} =
      Relays.all_connected_relays_for_account(socket.assigns.subject.account, except_ids)

    location = {
      socket.assigns.client.last_seen_remote_ip_location_lat,
      socket.assigns.client.last_seen_remote_ip_location_lon
    }

    relays = Relays.load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp maybe_subscribe_for_relays_presence(relays, socket) do
    if length(relays) > 0 do
      :ok
    else
      Relays.subscribe_to_relays_presence_in_account(socket.assigns.subject.account)
    end
  end

  defp generate_preshared_key(client, gateway) do
    Domain.Crypto.psk(client, gateway)
  end

  # Ice credentials must stay the same for all connections between client and gateway as long as they
  # do not loose their state, so we can leverage public_key which is reset on each restart of the client
  # or gateway.
  defp generate_ice_credentials(client, gateway) do
    ice_credential_seed =
      [
        client.id,
        client.public_key,
        gateway.id,
        gateway.public_key
      ]
      |> Enum.join(":")

    ice_credential_seed_hash =
      :crypto.hash(:sha256, ice_credential_seed)
      |> Base.encode32(case: :lower, padding: false)

    [
      {:client_username, client_username},
      {:client_password, client_password},
      {:gateway_username, gateway_username},
      {:gateway_password, gateway_password}
    ] =
      Enum.map(
        [
          client_username: 0..3,
          client_password: 4..25,
          gateway_username: 26..29,
          gateway_password: 30..52
        ],
        fn {key, range} ->
          {key, String.slice(ice_credential_seed_hash, range)}
        end
      )

    %{
      client: %{username: client_username, password: client_password},
      gateway: %{username: gateway_username, password: gateway_password}
    }
  end

  ##########################################
  #### Handling changes from the domain ####
  ##########################################

  # ACCOUNTS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Accounts.Account{} = old_account,
           struct: %Accounts.Account{} = account
         },
         socket
       ) do
    # Update our subject's account
    subject = %{socket.assigns.subject | account: account}
    socket = assign(socket, subject: subject)

    if old_account.config != account.config do
      client = %{socket.assigns.client | account: account}
      payload = %{interface: Views.Interface.render(client)}
      :ok = push(socket, "config_changed", payload)
    end

    {:noreply, socket}
  end

  # ACTOR_GROUP_MEMBERSHIPS

  defp handle_change(
         %Change{op: :insert, struct: %Actors.Membership{actor_id: actor_id}},
         %{assigns: %{client: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    Cache.Client.add_membership(socket.assigns.cache, socket.assigns.client)
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Actors.Membership{actor_id: actor_id} = membership
         },
         %{assigns: %{client: %{actor_id: id}}} = socket
       )
       when id == actor_id do
    Cache.Client.delete_membership(socket.assigns.cache, membership, socket.assigns.client)
    |> push_resource_updates(socket)
  end

  # CLIENTS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Clients.Client{} = old_client,
           struct: %Clients.Client{id: client_id} = client
         },
         %{assigns: %{client: %{id: id}}} = socket
       )
       when id == client_id do
    # Maintain our preloaded identity
    client = %{client | identity: socket.assigns.client.identity}
    socket = assign(socket, client: client)

    # Changes in client verification can affect the list of allowed resources
    if old_client.verified_at != client.verified_at do
      Cache.Client.recompute_connectable_resources(socket.assigns.cache, socket.assigns.client)
      |> push_resource_updates(socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Clients.Client{id: id}},
         %{assigns: %{client: %{id: client_id}}} = socket
       )
       when id == client_id do
    # Deleting a client won't necessary delete its tokens in the case of a headless client.
    # So we explicitly handle the deleted client here by forcing it to reconnect.
    {:stop, :shutdown, socket}
  end

  # GATEWAY_GROUPS

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Gateways.Group{name: old_name},
           struct: %Gateways.Group{name: name} = group
         },
         socket
       )
       when old_name != name do
    Cache.Client.update_resources_with_group_name(
      socket.assigns.cache,
      group,
      socket.assigns.client
    )
    |> push_resource_updates(socket)
  end

  # POLICIES

  defp handle_change(
         %Change{op: :insert, struct: %Policies.Policy{} = policy},
         socket
       ) do
    Cache.Client.add_policy(
      socket.assigns.cache,
      policy,
      socket.assigns.client,
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Policies.Policy{
             resource_id: old_resource_id,
             actor_group_id: old_actor_group_id,
             conditions: old_conditions
           },
           struct: %Policies.Policy{
             resource_id: resource_id,
             actor_group_id: actor_group_id,
             conditions: conditions,
             disabled_at: disabled_at
           }
         } = change,
         socket
       )
       when old_resource_id != resource_id or old_actor_group_id != actor_group_id or
              old_conditions != conditions do
    # TODO: Optimization
    # Breaking update - process this as a delete and then create to make our lives easier.
    # We could be smarter here and process the individual side effects more cleverly to avoid
    # sending resource_deleted and resource_created_or_updated if the policy is not actually changing
    # the client's connectable_resources.
    {:noreply, socket} = handle_change(%{change | op: :delete}, socket)

    # DO NOT re-add disabled policies
    if is_nil(disabled_at) do
      handle_change(%{change | op: :insert}, socket)
    else
      {:noreply, socket}
    end
  end

  # Other update, i.e. description - just update our state
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Policies.Policy{},
           struct: %Policies.Policy{} = policy
         },
         socket
       ) do
    Cache.Client.update_policy(socket.assigns.cache, policy)
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{op: :delete, old_struct: %Policies.Policy{} = policy},
         socket
       ) do
    Cache.Client.delete_policy(socket.assigns.cache, policy, socket.assigns.client)
    |> push_resource_updates(socket)
  end

  # RESOURCE_CONNECTIONS

  defp handle_change(
         %Change{
           op: :insert,
           struct: %Resources.Connection{} = connection
         },
         socket
       ) do
    Cache.Client.add_resource_connection(
      socket.assigns.cache,
      connection,
      socket.assigns.subject,
      socket.assigns.client
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Resources.Connection{} = connection
         },
         socket
       ) do
    Cache.Client.delete_resource_connection(
      socket.assigns.cache,
      connection,
      socket.assigns.client
    )
    |> push_resource_updates(socket)
  end

  # RESOURCES

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Resources.Resource{},
           struct: %Resources.Resource{} = resource
         },
         socket
       ) do
    Cache.Client.update_resource(
      socket.assigns.cache,
      resource,
      socket.assigns.client
    )
    |> push_resource_updates(socket)
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  defp push_resource_updates({:ok, added_resources, removed_ids, cache}, socket) do
    # TODO: Multi-site resources
    # Currently, connlib doesn't handle resources changing sites, so we need to delete then create.
    # We handle that scenario by sending resource_deleted then resource_created_or_updated, so it's
    # important that deletions are processed first here.
    # See https://github.com/firezone/firezone/issues/9881
    for resource_id <- removed_ids do
      push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      push(socket, "resource_created_or_updated", Views.Resource.render(resource))
    end

    {:noreply, assign(socket, cache: cache)}
  end
end
