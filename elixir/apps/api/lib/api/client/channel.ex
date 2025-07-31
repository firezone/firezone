defmodule API.Client.Channel do
  use API, :channel
  alias API.Client.Views

  alias Domain.{
    Accounts,
    Clients,
    Actors,
    PubSub,
    Resources,
    Flows,
    Gateways,
    Relays,
    Policies,
    Flows,
    Tokens
  }

  alias Domain.Relays.Presence.Debouncer
  require Logger
  require OpenTelemetry.Tracer

  # For time-based policy conditions, we need to determine whether we still have access
  # If not, we need to send resource_deleted so that if it's added back later, the client's
  # connlib state will be cleaned up so it can request a new connection.
  @recompute_authorized_resources_every :timer.minutes(1)

  @gateway_compatibility [
    # We introduced new websocket protocol and the clients of version 1.4+
    # are only compatible with gateways of version 1.4+
    {">= 1.4.0", ">= 1.4.0"},
    # The clients of version of 1.1+ are compatible with gateways of version 1.1+,
    # but the clients of versions prior to that can connect to any gateway
    {">= 1.1.0", ">= 1.1.0"}
  ]

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def join("client", _payload, socket) do
    with {:ok, socket} <- schedule_expiration(socket),
         {:ok, gateway_version_requirement} <-
           select_gateway_version_requirement(socket.assigns.client) do
      socket = assign(socket, gateway_version_requirement: gateway_version_requirement)

      send(self(), :after_join)

      {:ok, socket}
    end
  end

  defp schedule_expiration(%{assigns: %{subject: %{expires_at: expires_at}}} = socket) do
    expires_in =
      expires_at
      |> DateTime.diff(DateTime.utc_now(), :millisecond)

    if expires_in > 0 do
      Process.send_after(self(), :token_expired, expires_in)
      {:ok, socket}
    else
      {:error, %{reason: :token_expired}}
    end
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

    # Initialize the cache.
    socket =
      socket
      |> hydrate_policies_and_resources()
      |> hydrate_memberships()

    # Initialize relays
    {:ok, relays} = select_relays(socket)
    :ok = Enum.each(relays, &Relays.subscribe_to_relay_presence/1)
    :ok = maybe_subscribe_for_relays_presence(relays, socket)

    # Initialize debouncer for flappy relays
    socket = Debouncer.cache_stamp_secrets(socket, relays)

    # Track client's presence
    :ok = Clients.Presence.connect(socket.assigns.client)

    # Subscribe to all account updates
    :ok = PubSub.Account.subscribe(socket.assigns.client.account_id)

    # Initialize resources
    resources = authorized_resources(socket)

    # Save list of authorized resources in the socket to check against in
    # the recompute_authorized_resources timer
    socket = assign(socket, authorized_resource_ids: MapSet.new(Enum.map(resources, & &1.id)))

    # Delete any stale flows for resources we may not have access to anymore
    Flows.delete_stale_flows_on_connect(
      socket.assigns.client,
      resources
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

    {:noreply, socket}
  end

  # Needed to keep the client's resource list up to date for time-based policy conditions
  def handle_info(:recompute_authorized_resources, socket) do
    Process.send_after(
      self(),
      :recompute_authorized_resources,
      @recompute_authorized_resources_every
    )

    old_authorized_resources =
      Map.take(socket.assigns.resources, MapSet.to_list(socket.assigns.authorized_resource_ids))
      |> Map.values()

    new_authorized_resources = authorized_resources(socket)

    for resource <- old_authorized_resources -- new_authorized_resources do
      push(socket, "resource_deleted", resource.id)
    end

    for resource <- new_authorized_resources -- old_authorized_resources do
      push(socket, "resource_created_or_updated", Views.Resource.render(resource))
    end

    {:noreply,
     assign(socket,
       authorized_resource_ids: MapSet.new(Enum.map(new_authorized_resources, & &1.id))
     )}
  end

  # Called to actually push relays_presence with a disconnected relay to the client
  def handle_info({:push_leave, relay_id, stamp_secret, payload}, socket) do
    {:noreply, Debouncer.handle_leave(socket, relay_id, stamp_secret, payload, &push/3)}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  # ACCOUNTS

  def handle_info(
        {:updated, %Accounts.Account{} = old_account, %Accounts.Account{} = account},
        socket
      ) do
    # update our cached subject's account
    socket = assign(socket, subject: %{socket.assigns.subject | account: account})

    if old_account.config != account.config do
      payload = %{interface: Views.Interface.render(%{socket.assigns.client | account: account})}
      :ok = push(socket, "config_changed", payload)
    end

    {:noreply, socket}
  end

  # ACTOR_GROUP_MEMBERSHIPS

  def handle_info(
        {:created, %Actors.Membership{actor_id: actor_id, group_id: group_id} = membership},
        %{assigns: %{client: %{actor_id: id}}} = socket
      )
      when id == actor_id do
    # 1. Get existing authorized resources
    old_authorized_resources =
      Map.take(socket.assigns.resources, MapSet.to_list(socket.assigns.authorized_resource_ids))
      |> Map.values()

    # 2. Re-hydrate our policies and resources
    # It's not ideal we're hitting the DB here, but in practice it shouldn't be an issue because
    # periods of bursty membership creation typically only happen for new accounts or new directory
    # syncs, which won't have any policies associated.
    socket = hydrate_policies_and_resources(socket)

    # 3. Update our membership group IDs
    memberships = Map.put(socket.assigns.memberships, group_id, membership)
    socket = assign(socket, memberships: memberships)

    # 3. Compute new authorized resources
    new_authorized_resources = authorized_resources(socket)

    # 4. Push new resources to the client
    for resource <- new_authorized_resources -- old_authorized_resources do
      push(socket, "resource_created_or_updated", Views.Resource.render(resource))
    end

    socket =
      assign(socket,
        authorized_resource_ids: MapSet.new(Enum.map(new_authorized_resources, & &1.id))
      )

    {:noreply, socket}
  end

  def handle_info(
        {:deleted, %Actors.Membership{actor_id: actor_id, group_id: group_id}},
        %{assigns: %{client: %{actor_id: id}}} = socket
      )
      when id == actor_id do
    # 1. Take a snapshot of all resource_ids we no longer have access to
    deleted_resource_ids =
      socket.assigns.policies
      |> Enum.flat_map(fn {_id, policy} ->
        if policy.actor_group_id == group_id, do: [policy.resource_id], else: []
      end)
      |> Enum.uniq()

    # 2. Push deleted resources to the client
    for resource_id <- deleted_resource_ids do
      push(socket, "resource_deleted", resource_id)
    end

    # 3. Update our state
    policies =
      socket.assigns.policies
      |> Enum.filter(fn {_id, policy} -> policy.actor_group_id != group_id end)
      |> Enum.into(%{})

    r_ids = Enum.map(policies, fn {_id, policy} -> policy.resource_id end) |> Enum.uniq()
    resources = Map.take(socket.assigns.resources, r_ids)
    memberships = Map.delete(socket.assigns.memberships, group_id)

    socket =
      socket
      |> assign(policies: policies)
      |> assign(resources: resources)
      |> assign(memberships: memberships)

    {:noreply, socket}
  end

  # CLIENTS

  # Changes in client verification can affect the list of allowed resources - send diff of resources
  def handle_info(
        {:updated, %Clients.Client{} = old_client, %Clients.Client{id: client_id} = client},
        %{assigns: %{client: %{id: id}}} = socket
      )
      when id == client_id do
    # 1. Snapshot existing authorized resources
    old_authorized_resources =
      Map.take(socket.assigns.resources, MapSet.to_list(socket.assigns.authorized_resource_ids))
      |> Map.values()

    # 2. Update our state - maintain preloaded identity
    client = %{client | identity: socket.assigns.client.identity}
    socket = assign(socket, client: client)

    # 3. If client's verification status changed, send diff of resources
    socket =
      if old_client.verified_at != client.verified_at do
        new_authorized_resources = authorized_resources(socket)

        for resource <- new_authorized_resources -- old_authorized_resources do
          push(socket, "resource_created_or_updated", Views.Resource.render(resource))
        end

        for resource <- old_authorized_resources -- new_authorized_resources do
          push(socket, "resource_deleted", resource.id)
        end

        assign(socket,
          authorized_resource_ids: MapSet.new(Enum.map(new_authorized_resources, & &1.id))
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:deleted, %Clients.Client{id: id}},
        %{assigns: %{client: %{id: client_id}}} = socket
      )
      when id == client_id do
    disconnect(socket)
  end

  # GATEWAY_GROUPS

  def handle_info(
        {:updated, %Gateways.Group{} = old_group, %Gateways.Group{} = group},
        socket
      ) do
    resources =
      socket.assigns.resources
      |> Enum.map(fn {id, resource} ->
        gateway_groups =
          resource.gateway_groups
          |> Enum.map(fn gg -> if gg.id == group.id, do: Map.merge(gg, group), else: gg end)

        # Send resource_created_or_updated for all resources that have this group if name has changed
        if Enum.any?(gateway_groups, fn gg -> gg.name != old_group.name and gg.id == group.id end) do
          push(socket, "resource_created_or_updated", Views.Resource.render(resource))
        end

        {id, %{resource | gateway_groups: gateway_groups}}
      end)
      |> Enum.into(%{})

    socket = assign(socket, resources: resources)

    {:noreply, socket}
  end

  # POLICIES

  def handle_info({:created, %Policies.Policy{} = policy}, socket) do
    # 1. Check if this policy is for us
    if Map.has_key?(socket.assigns.memberships, policy.actor_group_id) do
      # 2. Snapshot existing resources
      old_authorized_resources =
        Map.take(socket.assigns.resources, MapSet.to_list(socket.assigns.authorized_resource_ids))
        |> Map.values()

      # 3. Hydrate a new resource if we aren't already tracking it
      socket =
        if Map.has_key?(socket.assigns.resources, policy.resource_id) do
          # Resource already exists due to another policy
          socket
        else
          {:ok, resource} =
            Resources.fetch_resource_by_id(policy.resource_id, socket.assigns.subject,
              preload: :gateway_groups
            )

          socket
          |> assign(resources: Map.put(socket.assigns.resources, resource.id, resource))
          |> assign(
            authorized_resource_ids:
              MapSet.put(socket.assigns.authorized_resource_ids, resource.id)
          )
        end

      # 4. Hydrate the new policy
      socket = assign(socket, policies: Map.put(socket.assigns.policies, policy.id, policy))

      # 5. Maybe send new resource
      if resource = (authorized_resources(socket) -- old_authorized_resources) |> List.first() do
        push(socket, "resource_created_or_updated", Views.Resource.render(resource))
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:updated,
         %Policies.Policy{
           resource_id: old_resource_id,
           actor_group_id: old_actor_group_id,
           conditions: old_conditions
         } = old_policy,
         %Policies.Policy{
           resource_id: resource_id,
           actor_group_id: actor_group_id,
           conditions: conditions,
           disabled_at: disabled_at
         } = policy},
        socket
      )
      when old_resource_id != resource_id or old_actor_group_id != actor_group_id or
             old_conditions != conditions do
    # Breaking update - process this as a delete and then create
    {:noreply, socket} = handle_info({:deleted, old_policy}, socket)

    if is_nil(disabled_at) do
      handle_info({:created, policy}, socket)
    else
      {:noreply, socket}
    end
  end

  # Other update - just update our state if the policy is for us
  def handle_info({:updated, %Policies.Policy{}, %Policies.Policy{} = policy}, socket) do
    socket =
      if Map.has_key?(socket.assigns.policies, policy.id) do
        assign(socket, policies: Map.put(socket.assigns.policies, policy.id, policy))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:deleted, %Policies.Policy{} = policy}, socket) do
    # 1. Check if this policy is for us
    if Map.has_key?(socket.assigns.policies, policy.id) do
      # 2. Snapshot existing resources
      old_authorized_resources =
        Map.take(socket.assigns.resources, MapSet.to_list(socket.assigns.authorized_resource_ids))
        |> Map.values()

      # 3. Update our state
      socket = assign(socket, policies: Map.delete(socket.assigns.policies, policy.id))
      r_ids = Enum.map(socket.assigns.policies, fn {_id, p} -> p.resource_id end) |> Enum.uniq()
      socket = assign(socket, resources: Map.take(socket.assigns.resources, r_ids))

      authorized_resources = authorized_resources(socket)

      socket =
        assign(socket,
          authorized_resource_ids: MapSet.new(Enum.map(authorized_resources, & &1.id))
        )

      # 4. Push deleted resource to the client if we lost access to it
      if resource = (old_authorized_resources -- authorized_resources) |> List.first() do
        push(socket, "resource_deleted", resource.id)
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # RESOURCE_CONNECTIONS

  def handle_info(
        {:created,
         %Resources.Connection{resource_id: resource_id, gateway_group_id: gateway_group_id}},
        socket
      ) do
    # 1. Check if this affects us
    if resource = socket.assigns.resources[resource_id] do
      # 2. Fetch the gateway_group to hydrate the site name
      {:ok, gateway_group} = Gateways.fetch_group_by_id(gateway_group_id, socket.assigns.subject)

      # 3. Update our state
      resource = %{resource | gateway_groups: resource.gateway_groups ++ [gateway_group]}
      socket = assign(socket, resources: Map.put(socket.assigns.resources, resource_id, resource))

      # 4. If resource is allowed, push
      if MapSet.member?(socket.assigns.authorized_resource_ids, resource.id) do
        # Connlib doesn't handle resources changing sites, so we need to delete then create
        # See https://github.com/firezone/firezone/issues/9881
        push(socket, "resource_deleted", resource.id)
        push(socket, "resource_created_or_updated", Views.Resource.render(resource))
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Resource connection is a required field on resources, so a delete will always be followed by a create.
  # This means connlib *should* never see a resource with no sites (gateway_groups).

  def handle_info(
        {:deleted,
         %Resources.Connection{resource_id: resource_id, gateway_group_id: gateway_group_id}},
        socket
      ) do
    # 1. Check if this affects us
    if resource = socket.assigns.resources[resource_id] do
      # 2. Update our state
      gateway_groups = Enum.reject(resource.gateway_groups, &(&1.id == gateway_group_id))
      resource = %{resource | gateway_groups: gateway_groups}
      socket = assign(socket, resources: Map.put(socket.assigns.resources, resource_id, resource))

      # 3. Tell connlib
      push(socket, "resource_deleted", resource.id)

      # 4. If resource is allowed, and has at least one site connected, push
      if MapSet.member?(socket.assigns.authorized_resource_ids, resource.id) and
           length(resource.gateway_groups) > 0 do
        # Connlib doesn't handle resources changing sites, so we need to delete then create
        # See https://github.com/firezone/firezone/issues/9881
        push(socket, "resource_created_or_updated", Views.Resource.render(resource))
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # RESOURCES

  def handle_info(
        {:updated, %Resources.Resource{} = old_resource, %Resources.Resource{id: id} = resource},
        socket
      ) do
    # 1. Check if this affects us
    if existing_resource = socket.assigns.resources[id] do
      # 2. Update our state - take gateway_groups from existing resource
      resource = %{resource | gateway_groups: existing_resource.gateway_groups}

      socket =
        assign(socket,
          resources: Map.put(socket.assigns.resources, id, resource)
        )

      # 3. If resource is allowed and had meaningful changes, push
      # GatewayGroup changes are handled in the Resources.Connection handler
      resource_changed? =
        old_resource.ip_stack != resource.ip_stack or
          old_resource.type != resource.type or
          old_resource.filters != resource.filters or
          old_resource.address != resource.address or
          old_resource.address_description != resource.address_description or
          old_resource.name != resource.name

      if MapSet.member?(socket.assigns.authorized_resource_ids, resource.id) and
           resource_changed? do
        push(socket, "resource_created_or_updated", Views.Resource.render(resource))
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # TOKENS

  def handle_info(
        {:deleted, %Tokens.Token{type: :client, id: id}},
        %{assigns: %{subject: %{token_id: token_id}}} = socket
      )
      when id == token_id do
    dbg("Token deleted, disconnecting client socket")
    disconnect(socket)
  end

  ####################################
  ##### Reacting to timed events #####
  ####################################

  # Message is scheduled by schedule_expiration/1 on topic join to be sent
  # when the client token/subject expires
  def handle_info(:token_expired, socket) do
    disconnect(socket)
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
          # TODO: WAL
          # Why are we unsubscribing and subscribing again?
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
            # TODO: WAL
            # Why are we unsubscribing and subscribing again?
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
        {:connect, socket_ref, resource_id, gateway_public_key, payload},
        socket
      ) do
    reply(
      socket_ref,
      {:ok,
       %{
         resource_id: resource_id,
         persistent_keepalive: 25,
         gateway_public_key: gateway_public_key,
         gateway_payload: payload
       }}
    )

    {:noreply, socket}
  end

  def handle_info(
        {:connect, _socket_ref, resource_id, gateway_group_id, gateway_id, gateway_public_key,
         gateway_ipv4, gateway_ipv6, preshared_key, ice_credentials},
        socket
      ) do
    reply_payload = %{
      resource_id: resource_id,
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
    location = {
      socket.assigns.client.last_seen_remote_ip_location_lat,
      socket.assigns.client.last_seen_remote_ip_location_lon
    }

    with {:ok, resource} <- Map.fetch(socket.assigns.resources, resource_id),
         {:ok, expires_at, policy} <- authorize_resource(socket, resource_id),
         {:ok, gateways} when gateways != [] <-
           Gateways.all_connected_gateways_for_resource(resource, socket.assigns.subject,
             preload: :group
           ),
         {:ok, gateways} <-
           filter_compatible_gateways(gateways, socket.assigns.gateway_version_requirement) do
      gateway = Gateways.load_balance_gateways(location, gateways, connected_gateway_ids)

      # TODO: Optimization
      # Move this to a Task.start that completes after broadcasting authorize_flow
      {:ok, flow} =
        Flows.create_flow(
          socket.assigns.client,
          gateway,
          resource_id,
          policy,
          Map.fetch!(socket.assigns.memberships, policy.actor_group_id).id,
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
             preshared_key: preshared_key
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

      {:error, :offline} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :offline
        })

        {:noreply, socket}

      {:error, :forbidden} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :forbidden
        })

        {:noreply, socket}

      :error ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :not_found
        })

        {:noreply, socket}

      {:ok, []} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :offline
        })

        {:noreply, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        push(socket, "flow_creation_failed", %{
          resource_id: resource_id,
          reason: :forbidden,
          violated_properties: violated_properties
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
    with {:ok, resource} <- Map.fetch(socket.assigns.resources, resource_id),
         {:ok, _policy, _expires_at} <- authorize_resource(socket, resource_id),
         {:ok, [_ | _] = gateways} <-
           Gateways.all_connected_gateways_for_resource(resource, socket.assigns.subject,
             preload: :group
           ),
         gateway_version_requirement =
           maybe_update_gateway_version_requirement(
             resource,
             socket.assigns.gateway_version_requirement
           ),
         {:ok, gateways} <- filter_compatible_gateways(gateways, gateway_version_requirement) do
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
      {:ok, []} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      :error ->
        {:reply, {:error, %{reason: :not_found}}, socket}

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
    with {:ok, resource} <- Map.fetch(socket.assigns.resources, resource_id),
         {:ok, policy, expires_at} <- authorize_resource(socket, resource_id),
         {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
         true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
      # TODO: Optimization
      {:ok, flow} =
        Flows.create_flow(
          socket.assigns.client,
          gateway,
          resource_id,
          policy,
          Map.fetch!(socket.assigns.memberships, policy.actor_group_id).id,
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

      :error ->
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
    with {:ok, resource} <- Map.fetch(socket.assigns.resources, resource_id),
         {:ok, policy, expires_at} <- authorize_resource(socket, resource_id),
         {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
         true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
      # TODO: Optimization
      {:ok, flow} =
        Flows.create_flow(
          socket.assigns.client,
          gateway,
          resource_id,
          policy,
          Map.fetch!(socket.assigns.memberships, policy.actor_group_id).id,
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

      :error ->
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

  defp select_gateway_version_requirement(client) do
    case Version.parse(client.last_seen_version) do
      {:ok, _version} ->
        gateway_version_requirement =
          Enum.find_value(
            @gateway_compatibility,
            fn {client_version_requirement, gateway_version_requirement} ->
              if Version.match?(client.last_seen_version, client_version_requirement) do
                gateway_version_requirement
              end
            end
          )

        {:ok, gateway_version_requirement || "> 0.0.0"}

      :error ->
        {:error, %{reason: :invalid_version}}
    end
  end

  # DEPRECATED IN 1.4
  defp maybe_update_gateway_version_requirement(resource, gateway_version_requirement) do
    case map_or_drop_compatible_resource(resource, "1.0.0") do
      {:cont, _resource} ->
        gateway_version_requirement

      :drop ->
        if resource.type == :internet do
          ">= 1.3.0"
        else
          ">= 1.2.0"
        end
    end
  end

  defp filter_compatible_gateways(gateways, gateway_version_requirement) do
    gateways
    |> Enum.filter(fn gateway ->
      Version.match?(gateway.last_seen_version, gateway_version_requirement)
    end)
    |> case do
      [] -> {:error, :not_found}
      gateways -> {:ok, gateways}
    end
  end

  # DEPRECATED IN 1.4
  defp map_and_filter_compatible_resources(resources, client_version) do
    Enum.flat_map(resources, fn resource ->
      case map_or_drop_compatible_resource(resource, client_version) do
        {:cont, resource} -> [resource]
        :drop -> []
      end
    end)
  end

  # DEPRECATED IN 1.4
  def map_or_drop_compatible_resource(resource, client_or_gateway_version) do
    cond do
      resource.gateway_groups == [] ->
        :drop

      resource.type == :internet and Version.match?(client_or_gateway_version, ">= 1.3.0") ->
        {:cont, resource}

      resource.type == :internet ->
        :drop

      Version.match?(client_or_gateway_version, ">= 1.2.0") ->
        {:cont, resource}

      true ->
        resource.address
        |> String.codepoints()
        |> Resources.map_resource_address()
        |> case do
          {:cont, address} -> {:cont, %{resource | address: address}}
          :drop -> :drop
        end
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

  defp disconnect(socket) do
    push(socket, "disconnect", %{reason: :token_expired})
    send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
    {:stop, :shutdown, socket}
  end

  # TODO: Optimization
  # We can reduce memory usage of this cache by an order of magnitude by storing
  # optimized versions of the fields we need to evaluate policy conditions and
  # render data to the client.
  defp hydrate_policies_and_resources(socket) do
    OpenTelemetry.Tracer.with_span "client.hydrate_policies_and_resources",
      attributes: %{
        account_id: socket.assigns.client.account_id
      } do
      {_policies, acc} =
        Policies.all_policies_for_actor!(socket.assigns.subject.actor)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, acc ->
          resources = Map.put(acc.resources, policy.resource_id, policy.resource)

          # Remove resource from policy to avoid storing twice
          policies = Map.put(acc.policies, policy.id, Map.delete(policy, :resource))

          {policy, Map.merge(acc, %{policies: policies, resources: resources})}
        end)

      assign(socket,
        policies: acc.policies,
        resources: acc.resources
      )
    end
  end

  defp hydrate_memberships(socket) do
    OpenTelemetry.Tracer.with_span "client.hydrate_memberships",
      attributes: %{
        account_id: socket.assigns.client.account_id
      } do
      memberships =
        Actors.all_memberships_for_actor!(socket.assigns.subject.actor)
        |> Enum.map(fn membership ->
          {membership.group_id, membership}
        end)
        |> Enum.into(%{})

      assign(socket, memberships: memberships)
    end
  end

  defp authorized_resources(socket) do
    OpenTelemetry.Tracer.with_span "client.authorized_resources",
      attributes: %{
        account_id: socket.assigns.client.account_id
      } do
      client = socket.assigns.client

      resource_ids =
        socket.assigns.policies
        |> Map.values()
        |> Policies.filter_by_conforming_policies_for_client(client)
        |> Enum.map(& &1.resource_id)
        |> Enum.uniq()

      socket.assigns.resources
      |> Map.take(resource_ids)
      |> Map.values()
      |> map_and_filter_compatible_resources(client.last_seen_version)
    end
  end

  # Returns either the longest authorized policy or an error tuple of violated properties
  defp authorize_resource(socket, resource_id) do
    OpenTelemetry.Tracer.with_span "client.authorize_resource",
      attributes: %{
        account_id: socket.assigns.client.account_id
      } do
      socket.assigns.policies
      |> Enum.filter(fn {_id, policy} -> policy.resource_id == resource_id end)
      |> Enum.map(fn {_id, policy} -> policy end)
      |> Policies.longest_conforming_policy_for_client(
        socket.assigns.client,
        socket.assigns.subject.expires_at
      )
    end
  end
end
