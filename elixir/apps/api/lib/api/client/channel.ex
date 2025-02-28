defmodule API.Client.Channel do
  use API, :channel
  alias API.Client.Views
  alias Domain.Instrumentation
  alias Domain.{Accounts, Clients, Actors, Resources, Gateways, Relays, Policies, Flows}
  require Logger
  require OpenTelemetry.Tracer

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
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.join" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      with {:ok, socket} <- schedule_expiration(socket),
           {:ok, gateway_version_requirement} <-
             select_gateway_version_requirement(socket.assigns.client) do
        socket =
          assign(socket,
            opentelemetry_ctx: opentelemetry_ctx,
            opentelemetry_span_ctx: opentelemetry_span_ctx,
            gateway_version_requirement: gateway_version_requirement
          )

        send(self(), {:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}})
        {:ok, socket}
      end
    end
  end

  defp schedule_expiration(%{assigns: %{subject: %{expires_at: nil}}} = socket) do
    {:ok, socket}
  end

  defp schedule_expiration(%{assigns: %{subject: %{expires_at: expires_at}}} = socket) do
    expires_in = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    # Protect from race conditions where the token might have expired during code execution
    expires_in = max(0, expires_in)
    # Expiration time is capped at 31 days even if IdP returns really long lived tokens
    expires_in = min(expires_in, 2_678_400_000)

    if expires_in > 0 do
      Process.send_after(self(), :token_expired, expires_in)
      {:ok, socket}
    else
      {:error, %{reason: :token_expired}}
    end
  end

  def init(socket) do
    OpenTelemetry.Tracer.with_span "client.init" do
      {:ok, resources} =
        Resources.all_authorized_resources(socket.assigns.subject,
          preload: [
            :gateway_groups
          ]
        )

      # We pre-filter them before subscribing to events to avoid accidentally rendering them later
      resources = Policies.pre_filter_non_conforming_resources(resources, socket.assigns.client)

      # We subscribe for all resource events but only care about update events,
      # where resource might be renamed which should be propagated to the UI.
      :ok =
        Enum.each(resources, fn resource ->
          :ok = Resources.unsubscribe_from_events_for_resource(resource)
          :ok = Resources.subscribe_to_events_for_resource(resource)
        end)

      # Subscribe for known gateway group names so that if they are updated - we can render change in the UI
      :ok =
        resources
        |> Enum.flat_map(& &1.gateway_groups)
        |> Enum.uniq()
        |> Enum.each(fn gateway_group ->
          :ok = Gateways.unsubscribe_from_group_updates(gateway_group)
          :ok = Gateways.subscribe_to_group_updates(gateway_group)
        end)

      # Return all connected relays for the account
      {:ok, relays} = select_relays(socket)
      :ok = Enum.each(relays, &Relays.subscribe_to_relay_presence/1)
      :ok = maybe_subscribe_for_relays_presence(relays, socket)

      resources =
        map_and_filter_compatible_resources(resources, socket.assigns.client.last_seen_version)

      push(socket, "init", %{
        resources: Views.Resource.render_many(resources),
        relays: Views.Relay.render_many(relays, socket.assigns.subject.expires_at),
        interface:
          Views.Interface.render(%{
            socket.assigns.client
            | account: socket.assigns.subject.account
          })
      })
    end
  end

  @impl true
  def handle_info({:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}}, socket) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.after_join" do
      :ok = Clients.connect_client(socket.assigns.client)

      # Subscribe for account config updates
      :ok = Accounts.subscribe_to_events_in_account(socket.assigns.client.account_id)

      # We subscribe for membership updates for all actor groups the client is a member of,
      :ok = Actors.subscribe_to_membership_updates_for_actor(socket.assigns.subject.actor)

      # We subscribe for policy access events for the actor and the groups the client is a member of,
      actor_group_ids = Actors.all_actor_group_ids!(socket.assigns.subject.actor)
      :ok = Enum.each(actor_group_ids, &Policies.subscribe_to_events_for_actor_group/1)
      :ok = Policies.subscribe_to_events_for_actor(socket.assigns.subject.actor)

      :ok = init(socket)

      {:noreply, socket}
    end
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  # This message is sent using Clients.broadcast_to_client/1 eg. when the client is deleted
  def handle_info("disconnect", socket) do
    OpenTelemetry.Tracer.with_span "client.disconnect" do
      push(socket, "disconnect", %{reason: :token_expired})
      send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
      {:stop, :shutdown, socket}
    end
  end

  # This event is broadcasted from the Accounts context whenever the account config is changed
  def handle_info(:config_changed, socket) do
    account = Accounts.fetch_account_by_id!(socket.assigns.client.account_id)

    :ok =
      push(socket, "config_changed", %{
        interface:
          Views.Interface.render(%{
            socket.assigns.client
            | account: account
          })
      })

    {:noreply, socket}
  end

  # Message is scheduled by schedule_expiration/1 on topic join to be sent
  # when the client token/subject expires
  def handle_info(:token_expired, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.token_expired" do
      push(socket, "disconnect", %{reason: :token_expired})
      {:stop, {:shutdown, :token_expired}, socket}
    end
  end

  # This event is broadcasted when client or actor group was changed (eg. renamed, verified, etc.),
  # so we just re-initialize the client the same way as after join to push the updates
  def handle_info(:updated, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.updated" do
      socket = assign(socket, client: Clients.fetch_client_by_id!(socket.assigns.client.id))
      :ok = init(socket)
      {:noreply, socket}
    end
  end

  # Resource is created
  def handle_info({:create_resource, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.resource_created",
      attributes: %{resource_id: resource_id} do
      with {:ok, resource} <-
             Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject,
               preload: [:gateway_groups]
             ),
           true <-
             Policies.client_conforms_any_on_connect?(
               socket.assigns.client,
               resource.authorized_by_policies
             ) do
        case map_or_drop_compatible_resource(
               resource,
               socket.assigns.client.last_seen_version
             ) do
          {:cont, resource} ->
            push(
              socket,
              "resource_created_or_updated",
              Views.Resource.render(resource)
            )

          :drop ->
            :ok
        end
      else
        {:error, _reason} ->
          :ok

        false ->
          :ok
      end

      {:noreply, socket}
    end
  end

  # Resource is updated, eg. renamed. We don't care about other changes
  # as the access is dictated by the policy events
  def handle_info({:update_resource, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.resource_updated",
      attributes: %{resource_id: resource_id} do
      with {:ok, resource} <-
             Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject,
               preload: [:gateway_groups]
             ),
           true <-
             Policies.client_conforms_any_on_connect?(
               socket.assigns.client,
               resource.authorized_by_policies
             ) do
        case map_or_drop_compatible_resource(
               resource,
               socket.assigns.client.last_seen_version
             ) do
          {:cont, resource} ->
            push(
              socket,
              "resource_created_or_updated",
              Views.Resource.render(resource)
            )

          :drop ->
            :ok
        end
      else
        {:error, _reason} ->
          :ok

        false ->
          :ok
      end

      {:noreply, socket}
    end
  end

  # This event is ignored because we will receive a reject_access message from
  # the Policies which will trigger a resource_deleted event
  def handle_info({:delete_resource, _resource_id}, socket) do
    {:noreply, socket}
  end

  # Those events are broadcasted by Actors whenever a membership is created or deleted
  def handle_info({:create_membership, _actor_id, group_id}, socket) do
    :ok = Policies.subscribe_to_events_for_actor_group(group_id)
    {:noreply, socket}
  end

  def handle_info({:delete_membership, _actor_id, group_id}, socket) do
    :ok = Policies.unsubscribe_from_events_for_actor_group(group_id)
    {:noreply, socket}
  end

  # This message is received when there is a policy created or enabled
  # allowing access to a resource by a client actor group
  def handle_info({:allow_access, policy_id, actor_group_id, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.allow_access",
      attributes: %{
        policy_id: policy_id,
        actor_group_id: actor_group_id,
        resource_id: resource_id
      } do
      :ok = Resources.unsubscribe_from_events_for_resource(resource_id)
      :ok = Resources.subscribe_to_events_for_resource(resource_id)

      case Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject,
             preload: [:gateway_groups]
           ) do
        {:ok, resource} ->
          case map_or_drop_compatible_resource(
                 resource,
                 socket.assigns.client.last_seen_version
               ) do
            {:cont, resource} ->
              push(
                socket,
                "resource_created_or_updated",
                Views.Resource.render(resource)
              )

            :drop ->
              :ok
          end

        {:error, _reason} ->
          :ok
      end

      {:noreply, socket}
    end
  end

  # This message is received when the policy
  # allowing access to a resource by a client actor group is deleted
  def handle_info({:reject_access, policy_id, actor_group_id, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.reject_access",
      attributes: %{
        policy_id: policy_id,
        actor_group_id: actor_group_id,
        resource_id: resource_id
      } do
      :ok = Resources.unsubscribe_from_events_for_resource(resource_id)

      # We potentially can re-create the flow but this will require keep tracking of client connections to gateways,
      # which is not worth it as this case should be pretty rare. Instead we just tell client to remove it
      # and the recreate it right away if there is another allowing access to it.
      push(socket, "resource_deleted", resource_id)

      case Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject,
             preload: [:gateway_groups]
           ) do
        {:ok, resource} ->
          case map_or_drop_compatible_resource(
                 resource,
                 socket.assigns.client.last_seen_version
               ) do
            {:cont, resource} ->
              push(
                socket,
                "resource_created_or_updated",
                Views.Resource.render(resource)
              )

            :drop ->
              :ok
          end

        {:error, _reason} ->
          :ok
      end

      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:relays:" <> relay_id,
          payload: %{leaves: leaves}
        },
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    if Map.has_key?(leaves, relay_id) do
      OpenTelemetry.Tracer.with_span "client.relays_presence",
        attributes: %{
          relay_id: relay_id
        } do
        :ok = Relays.unsubscribe_from_relay_presence(relay_id)

        {:ok, relays} = select_relays(socket, [relay_id])
        :ok = maybe_subscribe_for_relays_presence(relays, socket)

        :ok =
          Enum.each(relays, fn relay ->
            :ok = Relays.unsubscribe_from_relay_presence(relay)
            :ok = Relays.subscribe_to_relay_presence(relay)
          end)

        push(socket, "relays_presence", %{
          disconnected_ids: [relay_id],
          connected: Views.Relay.render_many(relays, socket.assigns.subject.expires_at)
        })

        {:noreply, socket}
      end
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
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    if Enum.count(joins) > 0 do
      OpenTelemetry.Tracer.with_span "client.account_relays_presence" do
        {:ok, relays} = select_relays(socket)

        if length(relays) > 0 do
          :ok = Relays.unsubscribe_from_relays_presence_in_account(socket.assigns.subject.account)

          :ok =
            Enum.each(relays, fn relay ->
              :ok = Relays.unsubscribe_from_relay_presence(relay)
              :ok = Relays.subscribe_to_relay_presence(relay)
            end)

          push(socket, "relays_presence", %{
            disconnected_ids: [],
            connected: Views.Relay.render_many(relays, socket.assigns.subject.expires_at)
          })
        end

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
        {:ice_candidates, gateway_id, candidates, {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.ice_candidates",
      attributes: %{
        gateway_id: gateway_id,
        candidates_length: length(candidates)
      } do
      push(socket, "ice_candidates", %{
        gateway_id: gateway_id,
        candidates: candidates
      })

      {:noreply, socket}
    end
  end

  def handle_info(
        {:invalidate_ice_candidates, gateway_id, candidates,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.invalidate_ice_candidates",
      attributes: %{
        gateway_id: gateway_id,
        candidates_length: length(candidates)
      } do
      push(socket, "invalidate_ice_candidates", %{
        gateway_id: gateway_id,
        candidates: candidates
      })

      {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  # This message is sent by the gateway when it is ready to accept the connection from the client
  def handle_info(
        {:connect, socket_ref, resource_id, gateway_public_key, payload,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.connect", attributes: %{resource_id: resource_id} do
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
  end

  def handle_info(
        {:connect, _socket_ref, resource_id, gateway_group_id, gateway_id, gateway_public_key,
         gateway_ipv4, gateway_ipv6, preshared_key, ice_credentials,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.connect", attributes: %{resource_id: resource_id} do
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

      # We are pushing a message instead of replying for the sake of connlib message parsing convenience
      push(socket, "flow_created", reply_payload)
      # reply(socket_ref, {:ok, reply_payload})

      {:noreply, socket}
    end
  end

  ####################################
  ##### Client-initiated actions #####
  ####################################

  # This message sent by the client to create a GSC signed url for uploading logs and debug artifacts
  # TODO: This has been disabled on clients. Remove this when no more clients are requesting log sinks.
  @impl true
  def handle_in("create_log_sink", _attrs, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    account_slug = socket.assigns.subject.account.slug

    actor_name =
      socket.assigns.subject.actor.name
      |> String.downcase()
      |> String.replace(" ", "_")
      |> String.replace(~r/[^a-zA-Z0-9_-]/iu, "")

    OpenTelemetry.Tracer.with_span "client.create_log_sink" do
      case Instrumentation.create_remote_log_sink(socket.assigns.client, actor_name, account_slug) do
        {:ok, signed_url} ->
          {:reply, {:ok, signed_url}, socket}

        {:error, :disabled} ->
          {:reply, {:error, %{reason: :disabled}}, socket}

        {:error, reason} ->
          Logger.error("Failed to create log sink for client",
            client_id: socket.assigns.client.id,
            reason: inspect(reason)
          )

          {:reply, {:error, %{reason: :retry_later}}, socket}
      end
    end
  end

  # This message is sent to the client to request a network flow with a gateway that can serve given resource.
  #
  # `connected_gateway_ids` is used to indicate that the client is already connected to some of the gateways,
  # so the gateway can be reused by multiplexing the connection.
  def handle_in(
        "create_flow",
        %{
          "resource_id" => resource_id,
          "connected_gateway_ids" => connected_gateway_ids
        } = attrs,
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.create_flow", attributes: attrs do
      location = {
        socket.assigns.client.last_seen_remote_ip_location_lat,
        socket.assigns.client.last_seen_remote_ip_location_lon
      }

      with {:ok, resource} <-
             Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject),
           {:ok, gateways} when gateways != [] <-
             Gateways.all_connected_gateways_for_resource(resource, socket.assigns.subject,
               preload: :group
             ),
           {:ok, gateways} <-
             filter_compatible_gateways(gateways, socket.assigns.gateway_version_requirement),
           OpenTelemetry.Tracer.set_attribute(:gateways_count, length(gateways)),
           gateway = Gateways.load_balance_gateways(location, gateways, connected_gateway_ids),
           OpenTelemetry.Tracer.set_attribute(:gateway_id, gateway.id),
           {:ok, resource, flow} <-
             Flows.authorize_flow(
               socket.assigns.client,
               gateway,
               resource_id,
               socket.assigns.subject
             ) do
        OpenTelemetry.Tracer.set_attribute(:flow_id, flow.id)
        opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
        opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

        preshared_key = generate_preshared_key()
        ice_credentials = generate_ice_credentials(socket.assigns.client, gateway)

        :ok =
          Gateways.broadcast_to_gateway(
            gateway,
            {:authorize_flow, {self(), socket_ref(socket)},
             %{
               client_id: socket.assigns.client.id,
               resource_id: resource.id,
               flow_id: flow.id,
               authorization_expires_at: flow.expires_at,
               ice_credentials: ice_credentials,
               preshared_key: preshared_key
             }, {opentelemetry_ctx, opentelemetry_span_ctx}}
          )

        {:noreply, socket}
      else
        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")

          # We are pushing a message instead of replying for the sake of connlib message parsing convenience
          # {:reply, {:error, %{reason: :not_found}}, socket}

          push(socket, "flow_creation_failed", %{
            resource_id: resource_id,
            reason: :not_found
          })

          {:noreply, socket}

        {:ok, []} ->
          OpenTelemetry.Tracer.set_status(:error, "offline")

          # We are pushing a message instead of replying for the sake of connlib message parsing convenience
          # {:reply, {:error, %{reason: :offline}}, socket}

          push(socket, "flow_creation_failed", %{
            resource_id: resource_id,
            reason: :offline
          })

          {:noreply, socket}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          OpenTelemetry.Tracer.set_status(:error, "forbidden")

          # We are pushing a message instead of replying for the sake of connlib message parsing convenience
          # {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}}, socket}

          push(socket, "flow_creation_failed", %{
            resource_id: resource_id,
            reason: :forbidden,
            violated_properties: violated_properties
          })

          {:noreply, socket}
      end
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
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.prepare_connection", attributes: attrs do
      connected_gateway_ids = Map.get(attrs, "connected_gateway_ids", [])

      with {:ok, resource} <-
             Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject),
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

        OpenTelemetry.Tracer.set_attribute(:gateways_length, length(gateways))
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
          OpenTelemetry.Tracer.set_status(:error, "offline")
          {:reply, {:error, %{reason: :offline}}, socket}

        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")
          {:reply, {:error, %{reason: :not_found}}, socket}
      end
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
        } = attrs,
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.reuse_connection", attributes: attrs do
      with {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
           {:ok, resource, flow} <-
             Flows.authorize_flow(
               socket.assigns.client,
               gateway,
               resource_id,
               socket.assigns.subject
             ),
           true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
        opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
        opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

        :ok =
          Gateways.broadcast_to_gateway(
            gateway,
            {:allow_access, {self(), socket_ref(socket)},
             %{
               client_id: socket.assigns.client.id,
               resource_id: resource.id,
               flow_id: flow.id,
               authorization_expires_at: socket.assigns.subject.expires_at,
               client_payload: payload
             }, {opentelemetry_ctx, opentelemetry_span_ctx}}
          )

        {:noreply, socket}
      else
        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")
          {:reply, {:error, %{reason: :not_found}}, socket}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          OpenTelemetry.Tracer.set_status(:error, "forbidden")

          {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
           socket}

        false ->
          OpenTelemetry.Tracer.set_status(:error, "offline")
          {:reply, {:error, %{reason: :offline}}, socket}
      end
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
    ctx_attrs = %{gateway_id: gateway_id, resource_id: resource_id}
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.request_connection", attributes: ctx_attrs do
      with {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
           {:ok, resource, flow} <-
             Flows.authorize_flow(
               socket.assigns.client,
               gateway,
               resource_id,
               socket.assigns.subject
             ),
           true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
        opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
        opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

        :ok =
          Gateways.broadcast_to_gateway(
            gateway,
            {:request_connection, {self(), socket_ref(socket)},
             %{
               client_id: socket.assigns.client.id,
               resource_id: resource.id,
               flow_id: flow.id,
               authorization_expires_at: socket.assigns.subject.expires_at,
               client_payload: client_payload,
               client_preshared_key: preshared_key
             }, {opentelemetry_ctx, opentelemetry_span_ctx}}
          )

        {:noreply, socket}
      else
        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")
          {:reply, {:error, %{reason: :not_found}}, socket}

        {:error, {:forbidden, violated_properties: violated_properties}} ->
          OpenTelemetry.Tracer.set_status(:error, "forbidden")

          {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
           socket}

        false ->
          OpenTelemetry.Tracer.set_status(:error, "offline")
          {:reply, {:error, %{reason: :offline}}, socket}
      end
    end
  end

  # The client pushes it's ICE candidates list and the list of gateways that need to receive it
  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.broadcast_ice_candidates" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      :ok =
        Enum.each(gateway_ids, fn gateway_id ->
          Gateways.broadcast_to_gateway(
            gateway_id,
            {:ice_candidates, socket.assigns.client.id, candidates,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )
        end)

      {:noreply, socket}
    end
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.broadcast_invalidated_ice_candidates" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      :ok =
        Enum.each(gateway_ids, fn gateway_id ->
          Gateways.broadcast_to_gateway(
            gateway_id,
            {:invalidate_ice_candidates, socket.assigns.client.id, candidates,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )
        end)

      {:noreply, socket}
    end
  end

  defp select_relays(socket, except_ids \\ []) do
    {:ok, relays} =
      Relays.all_connected_relays_for_account(socket.assigns.subject.account, except_ids)

    location = {
      socket.assigns.client.last_seen_remote_ip_location_lat,
      socket.assigns.client.last_seen_remote_ip_location_lon
    }

    OpenTelemetry.Tracer.set_attribute(:relays_length, length(relays))

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

  # We generate a new preshared key for each flow request, the client and gateway MUST
  # ignore it if this is for a connection that is already established.
  defp generate_preshared_key do
    Domain.Crypto.psk()
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
end
