defmodule PortalAPI.Device.Channel.Outbound do
  @moduledoc """
  The initiating half of a device channel.

  The device holds the resources it may reach in `Portal.Cache.Client`
  under the `:cache` assign and asks for an authorization whenever it wants
  to connect to one. The channel authorizes the request against the cache,
  picks the device that serves the resource through `Portal.Routing`, mints
  the connection's credentials, hands the authorization to the receiver's
  channel inside a `Portal.Queue` dispatch so it is persisted alongside, and
  releases the device once the receiver acknowledges.

  Two kinds of target exist. A resource is served by a device in its site
  and the receiver's acknowledgement comes back as `{:connect, ...}`. A
  device pool names another client, reached by address, whose channel
  acknowledges with `{:device_access_acked, ...}` the moment the
  authorization is on its socket.
  """

  import Phoenix.Channel, only: [push: 3, socket_ref: 1]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Authentication, Cache, Devices, PG, Presence}
  alias Portal.Repo.Batch
  alias PortalAPI.Client.Views
  alias PortalAPI.Device.Channel.{Core, Credentials, DeviceDomains}

  require Logger

  @recompute_every :timer.minutes(1)

  @doc false
  def policy_authorization_queue_opts do
    [
      name: :policy_authorization_queue,
      flush_interval: :timer.seconds(1),
      flush_threshold: 10_000,
      label: "policy authorization",
      on_flush: &flush_policy_authorizations/1
    ]
  end

  ####################################
  ##### The outbound view ############
  ####################################

  @doc """
  Loads the resources the device may reach. The sites it serves are read
  once here: they are left out of what it can connect to.
  """
  @spec hydrate(Phoenix.Socket.t()) :: {Phoenix.Socket.t(), [Cache.Cacheable.Resource.t()]}
  def hydrate(socket) do
    Process.send_after(self(), :recompute_authorized_resources, @recompute_every)

    device = Core.Database.preload_site_devices(Core.device(socket))
    socket = Core.put_device(socket, device)

    {:ok, resources, [], cache} =
      Cache.Client.recompute_connectable_resources(
        nil,
        device,
        socket.assigns.subject,
        protocol_version: Core.protocol_version(socket)
      )

    socket =
      socket
      |> assign(:cache, cache)
      |> assign(:pending_authorizations, %{})

    {socket, resources}
  end

  @doc """
  Time-based policy conditions can grant or take away access without any
  row changing, so the list is recomputed on a schedule. A resource that
  goes away is deleted on the device so its state is cleaned up should it
  come back.
  """
  @spec recompute(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def recompute(socket) do
    Process.send_after(self(), :recompute_authorized_resources, @recompute_every)

    Cache.Client.recompute_connectable_resources(
      socket.assigns.cache,
      Core.device(socket),
      socket.assigns.subject
    )
    |> push_resource_updates(socket)
  end

  @doc "Pushes what a cache update added and removed."
  @spec push_resource_updates(
          {:ok, [Cache.Cacheable.Resource.t()], [Ecto.UUID.t()], Cache.Client.t()},
          Phoenix.Socket.t()
        ) :: {:noreply, Phoenix.Socket.t()}
  def push_resource_updates({:ok, added_resources, removed_ids, cache}, socket) do
    for resource_id <- removed_ids do
      push(socket, "resource_deleted", resource_id)
    end

    for resource <- added_resources do
      push(socket, "resource_created_or_updated", render_resource(socket, resource))
    end

    {:noreply, assign(socket, :cache, cache)}
  end

  @doc "A resource as this device's protocol renders it."
  @spec render_resource(Phoenix.Socket.t(), Cache.Cacheable.Resource.t()) :: map()
  def render_resource(socket, resource) do
    Views.Resource.render(resource, Core.device(socket), Core.protocol_version(socket))
  end

  @doc "The resource list as this device's protocol renders it."
  @spec render_resources(Phoenix.Socket.t(), [Cache.Cacheable.Resource.t()]) :: [map()]
  def render_resources(socket, resources) do
    Views.Resource.render_many(resources, Core.device(socket), Core.protocol_version(socket))
  end

  @doc "The group ids the device's memberships give it, carried in its presence for pool checks."
  @spec group_ids(Phoenix.Socket.t()) :: [Ecto.UUID.t()]
  def group_ids(socket) do
    case socket.assigns[:cache] do
      %{memberships: memberships} ->
        for {gid_bytes, _mid_bytes} <- memberships, do: Ecto.UUID.load!(gid_bytes)

      _not_hydrated ->
        []
    end
  end

  @doc """
  A resource the device may reach changed its filters: a device serving it
  to this one through a pool is told, so it applies the new filters.
  """
  @spec maybe_push_resource_filters_updated(Phoenix.Socket.t(), Portal.Resource.t(), term(), term()) ::
          :ok
  def maybe_push_resource_filters_updated(_socket, _resource, filters, filters), do: :ok

  def maybe_push_resource_filters_updated(socket, resource, _old_filters, _filters) do
    if PortalAPI.Device.Channel.Inbound.serves_resource?(socket, resource.id) do
      resource = Cache.Cacheable.to_cache(resource)
      push(socket, "resource_filters_updated", Views.Resource.render_authorization(resource))
    end

    :ok
  end

  @doc "Tells the device a pool member's addresses are no longer reachable through the pool."
  @spec push_device_access_denied(Phoenix.Socket.t(), {tuple(), tuple()} | nil) :: :ok
  def push_device_access_denied(_socket, nil), do: :ok

  def push_device_access_denied(socket, {ipv4_tuple, ipv6_tuple}) do
    push(socket, "client_device_access_denied", %{
      ipv4: ipv4_tuple && to_string(:inet.ntoa(ipv4_tuple)),
      ipv6: ipv6_tuple && to_string(:inet.ntoa(ipv6_tuple)),
      reason: :forbidden
    })
  end

  ####################################
  ##### Posture rows #################
  ####################################

  @doc """
  Re-reads the device's posture rows and recomputes its resources when they
  changed. Read back rather than patched in memory, which also picks up a
  Defender row newly linked through an Intune row.
  """
  @spec refresh_posture_rows(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def refresh_posture_rows(socket) do
    device = Core.device(socket)
    rows = load_posture_rows(socket)

    if rows == device.posture do
      {:noreply, socket}
    else
      device = %{device | posture: rows}
      socket = Core.put_device(socket, device)

      Cache.Client.recompute_connectable_resources(socket.assigns.cache, device, socket.assigns.subject)
      |> push_resource_updates(socket)
    end
  end

  defp load_posture_rows(socket) do
    if Portal.Account.device_posture_enabled?(socket.assigns.subject.account) do
      Devices.Posture.rows_by_type(Core.device(socket))
    else
      %{}
    end
  end

  ####################################
  ##### Requesting authorizations ####
  ####################################

  @doc """
  The device asks to connect to a resource. A device pool is a request for
  one of its members by address; anything else is served by a device in
  the resource's site.
  """
  @spec request_authorization(Phoenix.Socket.t(), map()) :: {:noreply, Phoenix.Socket.t()}
  def request_authorization(socket, %{"resource_id" => resource_id} = payload) do
    case authorize_resource(socket, resource_id) do
      {:ok, %Cache.Cacheable.Resource{type: :device_pool} = resource, membership_id, policy_id,
       expires_at} ->
        request_pool_authorization(
          socket,
          resource_id,
          resource,
          membership_id,
          policy_id,
          expires_at,
          payload
        )

      result ->
        authorized_gateway_resource(
          socket,
          result,
          resource_id,
          Map.get(payload, "connected_gateway_ids", [])
        )
    end
  end

  @doc """
  Connlib matched a packet against its resources and asks for access through
  them, most preferred first. A packet for a device in the tunnel range names
  the pools whose filters permit it and carries the address; the portal grants
  the first pool that holds the device. Any other packet names the one
  resource connlib routes it through.
  """
  @spec request_access(Phoenix.Socket.t(), map()) :: {:noreply, Phoenix.Socket.t()}
  def request_access(socket, %{"resource_ids" => resource_ids} = payload)
      when is_list(resource_ids) and resource_ids != [] do
    with {:ok, resource_ids} <- parse_resource_ids(resource_ids) do
      case parse_target_address(payload) do
        {:ok, target} ->
          request_device_access(socket, resource_ids, target, payload)

        {:error, :missing_address} ->
          request_resource_access(socket, hd(resource_ids), payload)

        {:error, reason} ->
          push_denied(socket, payload, reason)
      end
    else
      :error -> push_denied(socket, payload, :invalid_resource_ids)
    end
  end

  def request_access(socket, payload) do
    push_denied(socket, payload, :missing_resource_ids)
  end

  # DEPRECATED IN 1.4
  @doc false
  def prepare_connection(socket, %{"resource_id" => resource_id} = attrs) do
    device = Core.device(socket)
    connected_gateway_ids = Map.get(attrs, "connected_gateway_ids", [])

    with {:ok, resource, _membership_id, _policy_id, _expires_at} <-
           authorize_resource(socket, resource_id),
         {:ok, gateways} when gateways != [] <-
           Portal.Routing.candidates(resource, device, socket.assigns.client_version) do
      gateway = Portal.Routing.select_receiver(gateways, location(socket), connected_gateway_ids)

      reply =
        {:ok,
         %{
           resource_id: resource_id,
           site_id: Ecto.UUID.load!(resource.site.id),
           gateway_id: gateway.id,
           gateway_remote_ip: gateway.last_seen_remote_ip
         }}

      {:reply, reply, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:ok, []} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, :version_mismatch} ->
        {:reply, {:error, %{reason: :version_mismatch}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}
    end
  end

  # DEPRECATED IN 1.4
  @doc false
  def reuse_connection(socket, %{
        "gateway_id" => gateway_id,
        "resource_id" => resource_id,
        "payload" => payload
      }) do
    device = Core.device(socket)

    with {:ok, resource, membership_id, policy_id, expires_at} <-
           authorize_resource(socket, resource_id),
         {:ok, gateway} <- Presence.Devices.fetch_gateway(socket.assigns.subject.account.id, gateway_id),
         true <- gateway_serves_resource_site?(gateway, resource) do
      policy_authorization_id = Ecto.UUID.generate()

      attrs =
        policy_authorization_attrs(
          socket,
          policy_authorization_id,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          expires_at
        )

      message =
        {:allow_access, {self(), socket_ref(socket)},
         %{
           client_id: device.id,
           client_ipv4: device.ipv4,
           client_ipv6: device.ipv6,
           resource: resource,
           policy_authorization_id: policy_authorization_id,
           authorization_expires_at: expires_at,
           client_payload: payload
         }}

      case enqueue(attrs, gateway.id, message) do
        :ok -> {:noreply, socket}
        {:error, _reason} -> {:reply, {:error, %{reason: :offline}}, socket}
      end
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, :offline} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  # DEPRECATED IN 1.4
  @doc false
  def request_connection(socket, %{
        "gateway_id" => gateway_id,
        "resource_id" => resource_id,
        "client_payload" => client_payload,
        "client_preshared_key" => preshared_key
      }) do
    device = Core.device(socket)

    with {:ok, resource, membership_id, policy_id, expires_at} <-
           authorize_resource(socket, resource_id),
         {:ok, gateway} <- Presence.Devices.fetch_gateway(socket.assigns.subject.account.id, gateway_id),
         true <- gateway_serves_resource_site?(gateway, resource) do
      policy_authorization_id = Ecto.UUID.generate()

      attrs =
        policy_authorization_attrs(
          socket,
          policy_authorization_id,
          gateway,
          resource_id,
          policy_id,
          membership_id,
          expires_at
        )

      message =
        {:request_connection, {self(), socket_ref(socket)},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render_legacy(
               device,
               device.public_key,
               client_payload,
               preshared_key
             ),
           resource: resource,
           policy_authorization_id: policy_authorization_id,
           authorization_expires_at: expires_at
         }}

      case enqueue(attrs, gateway.id, message) do
        :ok -> {:noreply, socket}
        {:error, _reason} -> {:reply, {:error, %{reason: :offline}}, socket}
      end
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: :not_found}}, socket}

      {:error, :offline} ->
        {:reply, {:error, %{reason: :offline}}, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        {:reply, {:error, %{reason: :forbidden, violated_properties: violated_properties}},
         socket}

      false ->
        {:reply, {:error, %{reason: :offline}}, socket}
    end
  end

  ####################################
  ##### Replies from receivers #######
  ####################################

  # DEPRECATED IN 1.4
  @doc false
  def legacy_connect(socket, socket_ref, rid_bytes, gateway_public_key, payload) do
    Phoenix.Channel.reply(
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

  @doc """
  The device serving a resource acknowledged the authorization. The device
  here is released with the receiver's keys and credentials, unless the
  request already timed out, in which case the late answer is dropped.
  """
  @spec connect(Phoenix.Socket.t(), binary(), term(), Ecto.UUID.t(), binary(), term(), term(), binary(), map(), boolean()) ::
          {:noreply, Phoenix.Socket.t()}
  def connect(
        socket,
        rid_bytes,
        site_id,
        gateway_id,
        gateway_public_key,
        gateway_ipv4,
        gateway_ipv6,
        preshared_key,
        ice_credentials,
        use_iceless
      ) do
    resource_id = Ecto.UUID.load!(rid_bytes)

    case Map.pop(socket.assigns.pending_authorizations, resource_id) do
      {nil, _} ->
        {:noreply, socket}

      {{_generation, timer_ref, initiator_token, address}, remaining} ->
        Process.cancel_timer(timer_ref)

        reply_payload =
          %{
            resource_id: resource_id,
            preshared_key: preshared_key,
            client_ice_credentials: ice_credentials.initiator,
            gateway_id: gateway_id,
            gateway_public_key: gateway_public_key,
            gateway_ipv4: gateway_ipv4,
            gateway_ipv6: gateway_ipv6,
            gateway_ice_credentials: ice_credentials.receiver,
            use_iceless: use_iceless,
            flow_logs_ingest_token: initiator_token
          }
          |> put_site_id(connect_site_id(socket, rid_bytes, site_id), Core.device(socket))
          |> Map.merge(address_fields(address))

        push(socket, Core.protocol(socket).authorization_created_event(), reply_payload)
        {:noreply, assign(socket, :pending_authorizations, remaining)}
    end
  end

  @doc """
  The target client's channel confirmed the authorization is on its socket.
  Only now is it safe to release the device here: its ICE candidates travel
  the same socket as the authorization and must not overtake it.
  """
  @spec device_access_acked(Phoenix.Socket.t(), reference(), boolean(), String.t(), String.t()) ::
          {:noreply, Phoenix.Socket.t()}
  def device_access_acked(socket, ref, use_iceless, client_name, client_slug) do
    case Map.pop(socket.assigns.pending_authorizations, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{timer_ref: timer_ref, initiator_payload: initiator_payload}, remaining} ->
        Process.cancel_timer(timer_ref)

        initiator_payload =
          initiator_payload
          |> Map.put(:use_iceless, use_iceless)
          |> Map.put(:client_name, client_name)
          |> Map.put(:client_slug, client_slug)

        push(socket, "client_device_access_authorized", initiator_payload)
        {:noreply, assign(socket, :pending_authorizations, remaining)}
    end
  end

  @doc """
  No answer came for a resource request. `generation` rejects a stale timer
  whose entry a newer request for the same resource already replaced.
  """
  @spec authorization_timed_out(Phoenix.Socket.t(), Ecto.UUID.t(), reference()) ::
          {:noreply, Phoenix.Socket.t()}
  def authorization_timed_out(socket, resource_id, generation) do
    case Map.get(socket.assigns.pending_authorizations, resource_id) do
      {^generation, _timer_ref, _initiator_token, address} ->
        push_authorization_creation_failed(socket, resource_id, :offline, address)

        {:noreply,
         assign(
           socket,
           :pending_authorizations,
           Map.delete(socket.assigns.pending_authorizations, resource_id)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @doc "No answer came from a target client: it disconnected in the window."
  @spec device_access_timed_out(Phoenix.Socket.t(), reference()) :: {:noreply, Phoenix.Socket.t()}
  def device_access_timed_out(socket, ref) do
    case Map.pop(socket.assigns.pending_authorizations, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{deny_payload: deny_payload}, remaining} ->
        push(socket, "client_device_access_denied", deny_payload)
        {:noreply, assign(socket, :pending_authorizations, remaining)}
    end
  end

  @doc "Tells the device a request by address was denied, with the reason."
  @spec push_denied(Phoenix.Socket.t(), map(), atom()) :: {:noreply, Phoenix.Socket.t()}
  def push_denied(socket, payload, reason) do
    push(
      socket,
      "client_device_access_denied",
      %{ipv4: payload["ipv4"], ipv6: payload["ipv6"], reason: reason}
      |> maybe_put_client_id(payload["client_id"])
    )

    {:noreply, socket}
  end

  ####################################
  ##### Resources served by sites ####
  ####################################

  defp request_resource_access(socket, resource_id, payload) do
    case authorize_resource(socket, resource_id) do
      {:ok, %Cache.Cacheable.Resource{type: :device_pool}, _membership_id, _policy_id, _expires_at} ->
        push(socket, Core.protocol(socket).authorization_creation_failed_event(), %{
          resource_id: resource_id,
          reason: :missing_address
        })

        {:noreply, socket}

      result ->
        authorized_gateway_resource(
          socket,
          result,
          resource_id,
          Map.get(payload, "connected_gateway_ids", [])
        )
    end
  end

  defp authorized_gateway_resource(socket, result, resource_id, connected_gateway_ids) do
    case result do
      {:ok, resource, membership_id, policy_id, expires_at} ->
        request_gateway_authorization(
          socket,
          resource_id,
          resource,
          membership_id,
          policy_id,
          expires_at,
          connected_gateway_ids,
          nil
        )

      {:error, :not_found} ->
        push(socket, Core.protocol(socket).authorization_creation_failed_event(), %{
          resource_id: resource_id,
          reason: :not_found
        })

        {:noreply, socket}

      {:error, {:forbidden, violated_properties: violated_properties}} ->
        push(socket, Core.protocol(socket).authorization_creation_failed_event(), %{
          resource_id: resource_id,
          reason: :forbidden,
          violated_properties: violated_properties
        })

        {:noreply, socket}
    end
  end

  defp request_gateway_authorization(
         socket,
         resource_id,
         resource,
         membership_id,
         policy_id,
         expires_at,
         connected_gateway_ids,
         address
       ) do
    device = Core.device(socket)

    case Portal.Routing.candidates(resource, device, socket.assigns.client_version) do
      {:ok, [_ | _] = gateways} ->
        gateway = Portal.Routing.select_receiver(gateways, location(socket), connected_gateway_ids)
        policy_authorization_id = Ecto.UUID.generate()

        %Credentials{
          preshared_key: preshared_key,
          ice_credentials: ice_credentials,
          initiator_ingest_token: initiator_token,
          responder_ingest_token: responder_token
        } =
          Credentials.generate(
            socket.assigns.subject,
            %{device: device, public_key: device.public_key},
            %{device: gateway, public_key: gateway.public_key},
            %{
              id: policy_authorization_id,
              policy_id: policy_id,
              resource: {Ecto.UUID.load!(resource.id), resource.name, resource.address},
              uploads_enabled?: flow_log_uploads_enabled?(socket.assigns.cache, policy_id),
              expires_at: expires_at
            }
          )

        message =
          {:create_authorization, {self(), socket_ref(socket)},
           %{
             client:
               PortalAPI.Gateway.Views.Client.render(
                 device,
                 device.public_key,
                 preshared_key,
                 socket.assigns.subject.context.user_agent
               ),
             # Kept for older gateways that do not report flow logs to the portal.
             # These do not parse the attribution fields from the ingest token.
             subject: PortalAPI.Gateway.Views.Subject.render(socket.assigns.subject),
             resource: PortalAPI.Gateway.Views.Resource.render(resource),
             policy_authorization_id: policy_authorization_id,
             authorization_expires_at: expires_at,
             ice_credentials: ice_credentials,
             preshared_key: preshared_key,
             initiator_iceless_capable: socket.assigns.iceless_capable,
             flow_logs_ingest_token: responder_token
           }}

        attrs =
          policy_authorization_attrs(
            socket,
            policy_authorization_id,
            gateway,
            resource_id,
            policy_id,
            membership_id,
            expires_at
          )

        case enqueue(attrs, gateway.id, message) do
          :ok ->
            {:noreply, arm_gateway_authorization_timer(socket, resource_id, initiator_token, address)}

          {:error, _reason} ->
            push_authorization_creation_failed(socket, resource_id, :offline, address)
            {:noreply, socket}
        end

      {:ok, []} ->
        push_authorization_creation_failed(socket, resource_id, :offline, address)
        {:noreply, socket}

      {:error, :version_mismatch} ->
        push_authorization_creation_failed(socket, resource_id, :version_mismatch, address)
        {:noreply, socket}
    end
  end

  defp push_authorization_creation_failed(socket, resource_id, reason, address) do
    push(
      socket,
      Core.protocol(socket).authorization_creation_failed_event(),
      Map.merge(%{resource_id: resource_id, reason: reason}, address_fields(address))
    )
  end

  defp arm_gateway_authorization_timer(socket, resource_id, initiator_token, address) do
    # A timer a prior in-flight request armed under this key is cancelled.
    case Map.get(socket.assigns.pending_authorizations, resource_id) do
      {_old_generation, old_timer_ref, _old_initiator_token, _old_address} ->
        Process.cancel_timer(old_timer_ref)

      nil ->
        :ok
    end

    generation = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:authorization_creation_timeout, resource_id, generation},
        authorization_creation_timeout()
      )

    assign(
      socket,
      :pending_authorizations,
      Map.put(
        socket.assigns.pending_authorizations,
        resource_id,
        {generation, timer_ref, initiator_token, address}
      )
    )
  end

  defp gateway_serves_resource_site?(_gateway, %{site: nil}), do: false

  defp gateway_serves_resource_site?(gateway, %{site: site}) do
    Portal.Device.serves_site?(gateway, Ecto.UUID.load!(site.id))
  end

  # The site the device is told about is the resource's, which a gateway
  # serving several sites cannot know; the gateway's own site stands in for
  # a resource that left the cache meanwhile.
  defp connect_site_id(socket, rid_bytes, gateway_site_id) do
    case Enum.find(socket.assigns.cache.connectable_resources, &(&1.id == rid_bytes)) do
      %{site: %{id: site_id_bytes}} -> Ecto.UUID.load!(site_id_bytes)
      _other -> gateway_site_id
    end
  end

  defp put_site_id(payload, site_id, device) do
    key =
      if Portal.Version.client_supports_sites_payload?(device),
        do: :site_id,
        else: :gateway_group_id

    Map.put(payload, key, site_id)
  end

  ####################################
  ##### Devices in pools #############
  ####################################

  defp request_device_access(socket, resource_ids, target, payload) do
    started_at = System.monotonic_time(:millisecond)
    device = Core.device(socket)
    account_id = device.account_id

    case find_online_client_by_address(account_id, target) do
      {:ok, target_client_id, target_meta} when target_client_id != device.id ->
        member = %{
          id: target_client_id,
          account_id: account_id,
          actor_id: target_meta.actor_id,
          group_ids: Map.get(target_meta, :group_ids, [])
        }

        case DeviceDomains.pick_device_pool(socket, resource_ids, member) do
          {:ok, resource, membership_id, policy_id, expires_at} ->
            authorized_pool_target(
              socket,
              target_client_id,
              target_meta,
              resource,
              membership_id,
              policy_id,
              expires_at,
              payload
            )

          {:error, :forbidden} ->
            deny_device_access(socket, payload, started_at)
        end

      {:ok, _self_id, _meta} ->
        deny_device_access(socket, payload, started_at)

      :offline ->
        with {:ok, %Portal.Device{} = target_device} <- DeviceDomains.fetch_target_device(socket, target),
             {:ok, _resource, _membership_id, _policy_id, _expires_at} <-
               DeviceDomains.pick_device_pool(socket, resource_ids, target_device) do
          push_denied(socket, Map.put(payload, "client_id", target_device.id), :offline)
        else
          _other -> deny_device_access(socket, payload, started_at)
        end
    end
  end

  # An address no device holds answers exactly like one the asking device may
  # not reach, and after the same delay, so sweeping the tunnel range tells an
  # actor nothing about who is in it.
  defp deny_device_access(socket, payload, started_at) do
    DeviceDomains.schedule_after_constant_time(started_at, {:device_access_denied, payload, :forbidden})

    {:noreply, socket}
  end

  defp request_pool_authorization(
         socket,
         resource_id,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload
       ) do
    device = Core.device(socket)

    with {:ok, target} <- parse_target_address(payload),
         {:ok, target_device_id} <- authorize_pool_target(resource, socket.assigns.cache, target) do
      # Once the target IP is authorized for the pool its device id is known,
      # so even offline-target denials carry it back.
      case find_online_client_by_address(device.account_id, target) do
        {:ok, target_client_id, target_meta} ->
          authorized_pool_target(
            socket,
            target_client_id,
            target_meta,
            resource,
            membership_id,
            policy_id,
            expires_at,
            payload
          )

        :offline ->
          push(socket, "client_device_access_denied", %{
            client_id: target_device_id,
            ipv4: payload["ipv4"],
            ipv6: payload["ipv6"],
            reason: :offline
          })

          {:noreply, socket}
      end
    else
      {:error, :ambiguous_address} ->
        Logger.warning("request_authorization for pool included both ipv4 and ipv6",
          client_id: device.id,
          resource_id: resource_id
        )

        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :ambiguous_address
        })

        {:noreply, socket}

      {:error, :missing_address} ->
        push(socket, "client_device_access_denied", %{
          resource_id: resource_id,
          reason: :missing_address
        })

        {:noreply, socket}

      {:error, :invalid_address} ->
        Logger.warning("Invalid IP address provided for pool device access request",
          client_id: device.id,
          account_id: device.account_id,
          account_slug: socket.assigns.subject.account.slug,
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"]
        )

        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :invalid_address
        })

        {:noreply, socket}

      {:error, :forbidden} ->
        push(socket, "client_device_access_denied", %{
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :forbidden
        })

        {:noreply, socket}
    end
  end

  # Target was found in presence: delivery is attempted and the authorization
  # persisted only when delivery succeeds.
  defp authorized_pool_target(
         socket,
         target_client_id,
         target_meta,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload
       ) do
    case check_peer_compatibility(socket, target_meta) do
      :ok ->
        deliver_pool_target_authorized(
          socket,
          target_client_id,
          target_meta,
          resource,
          membership_id,
          policy_id,
          expires_at,
          payload
        )

      {:error, :version_mismatch} ->
        push(socket, "client_device_access_denied", %{
          client_id: target_client_id,
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :version_mismatch
        })

        {:noreply, socket}
    end
  end

  defp deliver_pool_target_authorized(
         socket,
         target_client_id,
         target_meta,
         resource,
         membership_id,
         policy_id,
         expires_at,
         payload
       ) do
    device = Core.device(socket)
    resource_id = Ecto.UUID.load!(resource.id)
    policy_authorization_id = Ecto.UUID.generate()

    target_device = %Portal.Device{
      id: target_client_id,
      account_id: device.account_id,
      type: :client,
      last_seen_remote_ip: target_meta.remote_ip
    }

    attrs =
      policy_authorization_attrs(
        socket,
        policy_authorization_id,
        target_device,
        resource_id,
        policy_id,
        membership_id,
        expires_at
      )

    # Both messages are built before the queue's dispatch callback runs, so
    # the callback is only `PG.deliver/2` and cannot raise mid-flight: any
    # crash in crypto or rendering happens before anything is on the wire.
    #
    # `ref` correlates the target's ack with this request. The device is NOT
    # released on `Portal.Queue.enqueue/3` returning `:ok`, only once the
    # target's channel acks that the authorization is on its socket; until
    # then its ICE candidates would race ahead of the authorization.
    ref = make_ref()

    {receiver_message, initiator_payload} =
      build_client_device_access_authorized_messages(
        socket,
        target_client_id,
        target_meta,
        resource,
        policy_authorization_id,
        policy_id,
        expires_at,
        ref
      )

    case enqueue(attrs, target_client_id, receiver_message) do
      :ok ->
        timer_ref =
          Process.send_after(
            self(),
            {:authorization_creation_timeout, ref},
            authorization_creation_timeout()
          )

        pending =
          Map.put(socket.assigns.pending_authorizations, ref, %{
            timer_ref: timer_ref,
            initiator_payload: initiator_payload,
            deny_payload: %{
              client_id: target_client_id,
              ipv4: payload["ipv4"],
              ipv6: payload["ipv6"],
              reason: :offline
            }
          })

        {:noreply, assign(socket, :pending_authorizations, pending)}

      {:error, _} ->
        push(socket, "client_device_access_denied", %{
          client_id: target_client_id,
          ipv4: payload["ipv4"],
          ipv6: payload["ipv6"],
          reason: :offline
        })

        {:noreply, socket}
    end
  end

  # Returns `{receiver_message, initiator_payload}`. The receiver message goes
  # to the target's channel through PG inside the queue's dispatch so it
  # shares a sender pid with any later `:reject_access`; it carries
  # `{ack_to, ref}` so the target's channel can ack once the authorization is
  # on its socket, and only then is the initiator payload released here.
  defp build_client_device_access_authorized_messages(
         socket,
         target_client_id,
         target_meta,
         resource,
         policy_authorization_id,
         policy_id,
         expires_at,
         ref
       ) do
    device = Core.device(socket)
    public_key = device.public_key

    target_client = %Portal.Device{
      id: target_client_id,
      psk_base: target_meta.psk_base,
      type: :client
    }

    %Credentials{
      preshared_key: preshared_key,
      ice_credentials: ice_credentials,
      initiator_ingest_token: initiator_token,
      responder_ingest_token: responder_token
    } =
      Credentials.generate(
        socket.assigns.subject,
        %{device: device, public_key: public_key},
        %{device: target_client, public_key: target_meta.public_key},
        %{
          id: policy_authorization_id,
          policy_id: policy_id,
          resource: {Ecto.UUID.load!(resource.id), resource.name, resource.address},
          uploads_enabled?: flow_log_uploads_enabled?(socket.assigns.cache, policy_id),
          expires_at: expires_at
        }
      )

    # The receiving client gets the full resource view (filters, type, name,
    # devices) plus the subject view, in addition to the peer and ICE fields,
    # mirroring what a gateway is sent. Rendered with the initiator's session:
    # the receiver only reads the id and filters, so version skew is safe.
    rendered_resource = render_resource(socket, resource)
    rendered_subject = PortalAPI.Gateway.Views.Subject.render(socket.assigns.subject)

    receiver_message =
      {:client_device_access_authorized, {self(), ref},
       %{
         client_id: device.id,
         client_name: device.name,
         client_slug: device.slug,
         client_public_key: public_key,
         client_ipv4: device.ipv4,
         client_ipv6: device.ipv6,
         preshared_key: preshared_key,
         local_ice_credentials: ice_credentials.receiver,
         remote_ice_credentials: ice_credentials.initiator,
         ice_role: :controlled,
         resource: rendered_resource,
         subject: rendered_subject,
         policy_authorization_id: policy_authorization_id,
         authorization_expires_at: expires_at,
         initiator_iceless_capable: socket.assigns.iceless_capable,
         flow_logs_ingest_token: responder_token
       }}

    initiator_payload = %{
      client_id: target_client_id,
      resource_id: Ecto.UUID.load!(resource.id),
      client_public_key: target_meta.public_key,
      client_ipv4: %Postgrex.INET{address: target_meta.ipv4},
      client_ipv6: %Postgrex.INET{address: target_meta.ipv6},
      preshared_key: preshared_key,
      local_ice_credentials: ice_credentials.initiator,
      remote_ice_credentials: ice_credentials.receiver,
      ice_role: :controlling,
      flow_logs_ingest_token: initiator_token
    }

    {receiver_message, initiator_payload}
  end

  # Peer connections are refused when the target predates
  # `client_device_access_authorized` / `_denied` handling (older clients
  # silently drop the message, leaving the initiator waiting) or when the
  # two share no protocol range.
  defp check_peer_compatibility(socket, target_meta) do
    device = Core.device(socket)
    target_user_agent = Map.get(target_meta, :user_agent)
    target_version = Map.get(target_meta, :version)

    initiator_range =
      device.proto_range || Portal.Version.proto_range(nil, :client, device.last_seen_version)

    target_range = Portal.Version.proto_range_from_meta(target_meta, :client)

    if Portal.Version.supports_device_access?(target_user_agent, target_version) and
         Portal.Version.compatible?(initiator_range, target_range) do
      :ok
    else
      {:error, :version_mismatch}
    end
  end

  defp authorize_pool_target(%Cache.Cacheable.Resource{id: rid_bytes}, cache, target) do
    Cache.Client.authorize_device_access(cache, Ecto.UUID.load!(rid_bytes), target)
  end

  defp find_online_client_by_address(account_id, {:ipv4, ipv4_tuple}) do
    case Presence.Devices.Account.find_by_ipv4(account_id, ipv4_tuple) do
      {target_client_id, target_meta} -> {:ok, target_client_id, target_meta}
      nil -> :offline
    end
  end

  defp find_online_client_by_address(account_id, {:ipv6, ipv6_tuple}) do
    case Presence.Devices.Account.find_by_ipv6(account_id, ipv6_tuple) do
      {target_client_id, target_meta} -> {:ok, target_client_id, target_meta}
      nil -> :offline
    end
  end

  ####################################
  ##### Persisting authorizations ####
  ####################################

  # The authorization is written through the queue; the receiver's channel
  # gets the message from the queue's dispatch so both share a sender, and a
  # failed flush reaches it as `:reject_access` from the same place.
  defp enqueue(attrs, receiver_id, {tag, ref_tuple, payload}) do
    policy_authorization = struct(Portal.PolicyAuthorization, attrs)
    message = {tag, ref_tuple, Map.put(payload, :policy_authorization, policy_authorization)}

    Portal.Queue.enqueue(:policy_authorization_queue, attrs,
      dispatch: fn -> PG.deliver(receiver_id, message) end
    )
  end

  defp policy_authorization_attrs(
         socket,
         policy_authorization_id,
         %{id: receiving_device_id, account_id: account_id, last_seen_remote_ip: receiver_remote_ip},
         resource_id,
         policy_id,
         membership_id,
         expires_at
       ) do
    %Portal.Device{id: device_id, account_id: ^account_id, actor_id: actor_id} = Core.device(socket)

    %Authentication.Subject{
      account: %{id: ^account_id},
      actor: %{id: ^actor_id},
      credential: %{id: token_id},
      context: %Authentication.Context{
        remote_ip: initiator_remote_ip,
        user_agent: initiator_user_agent
      }
    } = socket.assigns.subject

    %{
      id: policy_authorization_id,
      token_id: token_id,
      policy_id: policy_id,
      initiating_device_id: device_id,
      receiving_device_id: receiving_device_id,
      resource_id: resource_id,
      membership_id: membership_id,
      account_id: account_id,
      initiator_remote_ip: initiator_remote_ip,
      initiator_user_agent: initiator_user_agent,
      receiver_remote_ip: receiver_remote_ip,
      expires_at: expires_at
    }
  end

  # Whether flow logs may be uploaded for a flow this policy authorizes, which
  # is to say whether the policy has opted out. Stamped into the ingest token
  # so devices know whether to upload and the ingest endpoint can enforce it.
  # A policy missing from the cache fails closed to false.
  defp flow_log_uploads_enabled?(cache, policy_id) do
    match?(
      %Cache.Cacheable.Policy{flow_log_uploads_enabled: true},
      Map.get(cache.policies, Ecto.UUID.dump!(policy_id))
    )
  end

  defp flush_policy_authorizations(entries) do
    {inserted, failed} =
      Batch.insert_all(Portal.PolicyAuthorization, entries,
        label: "policy authorization",
        fk_partitions: %{
          "policy_authorizations_account_id_fkey" => {:simple, :account_id, Portal.Account},
          "policy_authorizations_policy_id_fkey" => {:composite, :policy_id, Portal.Policy},
          "policy_authorizations_resource_id_fkey" => {:composite, :resource_id, Portal.Resource},
          "policy_authorizations_token_id_fkey" => {:composite, :token_id, Portal.ClientToken},
          "policy_authorizations_membership_id_fkey" =>
            {:composite_optional, :membership_id, Portal.Membership},
          "policy_authorizations_initiating_device_id_fkey" =>
            {:composite, :initiating_device_id, Portal.Device},
          "policy_authorizations_receiving_device_id_fkey" =>
            {:composite, :receiving_device_id, Portal.Device}
        }
      )

    dispatch_failed_policy_authorizations(failed)
    dispatch_confirmed_policy_authorizations(entries, failed)

    if failed != [] do
      Logger.warning(
        "Skipped #{length(failed)} policy authorization entries during flush due to missing references"
      )
    end

    inserted
  end

  defp dispatch_failed_policy_authorizations(failed) do
    for {attrs, _metadata} <- failed do
      dispatch_queue_callback("policy authorization", :on_failed, attrs, fn ->
        policy_authorization = struct(Portal.PolicyAuthorization, attrs)
        PG.deliver(attrs.receiving_device_id, {:reject_access, policy_authorization})
      end)
    end
  end

  defp dispatch_confirmed_policy_authorizations(entries, failed) do
    failed_ids = MapSet.new(failed, fn {attrs, _metadata} -> attrs[:id] end)

    for {attrs, _metadata} <- entries, not MapSet.member?(failed_ids, attrs[:id]) do
      dispatch_queue_callback("policy authorization", :on_confirmed, attrs, fn ->
        PG.deliver(attrs.receiving_device_id, {:confirm_authz_durability, attrs.id})
      end)
    end
  end

  defp dispatch_queue_callback(label, callback, attrs, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error(
        "Queue #{label} #{callback} crashed for entry #{inspect(attrs[:id])}: " <>
          Exception.message(error)
      )
  catch
    kind, reason ->
      Logger.error(
        "Queue #{label} #{callback} threw #{kind} for entry #{inspect(attrs[:id])}: " <>
          inspect(reason)
      )
  end

  ####################################
  ##### Helpers ######################
  ####################################

  defp authorize_resource(socket, resource_id) do
    Cache.Client.authorize_resource(
      socket.assigns.cache,
      Core.device(socket),
      resource_id,
      socket.assigns.subject
    )
  end

  defp location(socket) do
    {
      socket.assigns.subject.context.remote_ip_location_lat,
      socket.assigns.subject.context.remote_ip_location_lon
    }
  end

  defp authorization_creation_timeout do
    Portal.Config.get_env(:portal, :authorization_creation_timeout_ms, :timer.seconds(15))
  end

  defp parse_resource_ids(resource_ids) do
    Enum.reduce_while(resource_ids, {:ok, []}, fn resource_id, {:ok, acc} ->
      case Ecto.UUID.cast(resource_id) do
        {:ok, resource_id} -> {:cont, {:ok, [resource_id | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, resource_ids} -> {:ok, Enum.reverse(resource_ids)}
      :error -> :error
    end
  end

  defp parse_target_address(%{"ipv4" => ipv4, "ipv6" => ipv6})
       when is_binary(ipv4) and is_binary(ipv6),
       do: {:error, :ambiguous_address}

  defp parse_target_address(%{"ipv4" => ipv4_string}) when is_binary(ipv4_string) do
    case :inet.parse_address(String.to_charlist(ipv4_string)) do
      {:ok, {_, _, _, _} = tuple} -> {:ok, {:ipv4, tuple}}
      _ -> {:error, :invalid_address}
    end
  end

  defp parse_target_address(%{"ipv6" => ipv6_string}) when is_binary(ipv6_string) do
    case :inet.parse_address(String.to_charlist(ipv6_string)) do
      {:ok, {_, _, _, _, _, _, _, _} = tuple} -> {:ok, {:ipv6, tuple}}
      _ -> {:error, :invalid_address}
    end
  end

  defp parse_target_address(_), do: {:error, :missing_address}

  defp address_fields(nil), do: %{}
  defp address_fields({:ipv4, tuple}), do: %{ipv4: to_string(:inet.ntoa(tuple))}
  defp address_fields({:ipv6, tuple}), do: %{ipv6: to_string(:inet.ntoa(tuple))}

  defp maybe_put_client_id(payload, nil), do: payload
  defp maybe_put_client_id(payload, client_id), do: Map.put(payload, :client_id, client_id)
end
