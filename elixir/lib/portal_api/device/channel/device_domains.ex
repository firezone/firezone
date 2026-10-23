defmodule PortalAPI.Device.Channel.DeviceDomains do
  @moduledoc """
  Names in `firezone.network`, the domain of a device's pools.

  Connlib forwards queries for `<slug>.firezone.network` and PTR queries for
  the domain and every name under it. A name the device may reach resolves
  straight away; every other name answers after the same delay, so the
  account's devices cannot be listed by guessing names.
  """

  import Phoenix.Channel, only: [push: 3]

  alias Portal.Cache
  alias PortalAPI.Device.Channel.Core

  # A device lookup that the asking device may not have answers after this
  # long, whether or not anything is behind the name or address.
  @lookup_constant_time 500

  # How long, in seconds, connlib and the resolvers behind it may cache what a
  # PTR query in the device domain lists.
  @browse_ttl 30

  # The most PTR records a DNS message holds, even with compressed
  # one-character labels.
  @browse_limit 4_096

  @doc "Resolves `<slug>.firezone.network` to the device's tunnel addresses."
  @spec resolve(Phoenix.Socket.t(), String.t()) :: {:noreply, Phoenix.Socket.t()}
  def resolve(socket, domain) do
    started_at = System.monotonic_time(:millisecond)

    case resolve_device_domain(socket, domain) do
      {:ok, %Portal.Device{} = device} ->
        push(socket, "device_domain_resolved", %{
          domain: domain,
          ipv4: to_string(:inet.ntoa(device.ipv4.address)),
          ipv6: to_string(:inet.ntoa(device.ipv6.address))
        })

      {:error, reason} ->
        schedule_after_constant_time(started_at, {:device_domain_resolution_failed, domain, reason})
    end

    {:noreply, socket}
  end

  @doc """
  Lists the domain itself, the labels of the pools the device may use, or
  under such a label the devices in those pools, most recently seen first. A
  listing holds at most `#{@browse_limit}` names; `total` counts those it
  would hold without the cap.
  """
  @spec browse(Phoenix.Socket.t(), String.t()) :: {:noreply, Phoenix.Socket.t()}
  def browse(socket, domain) do
    started_at = System.monotonic_time(:millisecond)

    case browse_device_domain(socket, domain) do
      {:ok, labels, total} ->
        push(socket, "device_domain_browsed", %{
          domain: domain,
          names: Enum.map(labels, &Portal.Device.fqdn_for_slug/1),
          ttl: @browse_ttl,
          total: total
        })

      {:error, :not_found} ->
        schedule_after_constant_time(started_at, {:device_domain_browse_failed, domain})
    end

    {:noreply, socket}
  end

  @doc "Sends `message` to this channel once the constant lookup time has passed."
  @spec schedule_after_constant_time(integer(), term()) :: reference()
  def schedule_after_constant_time(started_at, message) do
    Process.send_after(
      self(),
      message,
      Portal.Timing.remaining_constant_time(started_at, @lookup_constant_time)
    )
  end

  @doc """
  Walks the pools connlib named, in its order, and grants the first the
  device may use that holds the target.
  """
  @spec pick_device_pool(Phoenix.Socket.t(), [Ecto.UUID.t()], map()) ::
          {:ok, Cache.Cacheable.Resource.t(), term(), term(), term()} | {:error, :forbidden}
  def pick_device_pool(socket, resource_ids, target) do
    cache = socket.assigns.cache
    device = Core.device(socket)
    subject = socket.assigns.subject

    Enum.find_value(resource_ids, {:error, :forbidden}, fn resource_id ->
      with {:ok, pool} <- fetch_connectable_device_pool(cache, resource_id),
           true <-
             Portal.Resource.DeviceMembershipCriteria.member?(
               pool.device_membership_criteria,
               target,
               subject
             ),
           {:ok, _resource, _membership_id, _policy_id, _expires_at} = authorized <-
             Cache.Client.authorize_resource(cache, device, resource_id, subject) do
        authorized
      else
        _ -> nil
      end
    end)
  end

  @doc "The device at `target` in this account, never the asking device itself."
  @spec fetch_target_device(Phoenix.Socket.t(), {:ipv4 | :ipv6, tuple()}) ::
          {:ok, Portal.Device.t()} | {:error, :not_found | :forbidden}
  def fetch_target_device(socket, target) do
    with {:ok, %Portal.Device{} = device} <-
           Core.Database.get_device_by_address(target, socket.assigns.subject) do
      if device.id == Core.device(socket).id do
        {:error, :forbidden}
      else
        {:ok, device}
      end
    end
  end

  defp fetch_connectable_device_pool(cache, resource_id) do
    rid_bytes = Ecto.UUID.dump!(resource_id)

    case Enum.find(cache.connectable_resources, &(&1.id == rid_bytes)) do
      %Cache.Cacheable.Resource{type: :device_pool} = pool -> {:ok, pool}
      _ -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp resolve_device_domain(socket, domain) do
    with {:ok, label} <- device_domain_label(domain) do
      resolve_device_label(socket, label)
    end
  end

  defp resolve_device_label(socket, label) do
    case fetch_reachable_device(socket, label) do
      {:ok, device} ->
        {:ok, device}

      {:error, :not_found} ->
        if List.keymember?(browsable_device_pools(socket), label, 0),
          do: {:error, :not_a_device},
          else: {:error, :not_found}
    end
  end

  defp browse_device_domain(socket, domain) do
    pools = browsable_device_pools(socket)

    if String.downcase(domain) == Portal.Device.domain() do
      labels = for {label, _pool} <- pools, uniq: true, do: label

      {:ok, labels |> Enum.sort() |> Enum.take(@browse_limit), length(labels)}
    else
      with {:ok, label} <- device_domain_label(domain) do
        browse_device_label(socket, label, pools)
      end
    end
  end

  defp browse_device_label(socket, label, pools) do
    criteria = for {^label, pool} <- pools, do: pool.device_membership_criteria

    case criteria do
      [] ->
        with {:ok, _device} <- fetch_reachable_device(socket, label), do: {:ok, [], 0}

      criteria ->
        {slugs, total} = Core.Database.member_slugs(criteria, @browse_limit, socket.assigns.subject)

        {:ok, slugs, total}
    end
  end

  defp device_domain_label(domain) do
    domain = String.downcase(domain)
    label = domain |> String.split(".") |> hd()

    if domain == Portal.Device.fqdn_for_slug(label),
      do: {:ok, label},
      else: {:error, :not_found}
  end

  defp fetch_reachable_device(socket, slug) do
    with {:ok, %Portal.Device{} = device} <-
           Core.Database.get_device_by_slug(slug, socket.assigns.subject),
         true <- reachable_through_any_pool?(socket, device) || {:error, :not_found} do
      {:ok, device}
    end
  end

  defp browsable_device_pools(socket) do
    cache = socket.assigns.cache
    device = Core.device(socket)
    subject = socket.assigns.subject

    pools =
      for %Cache.Cacheable.Resource{type: :device_pool, id: id} = pool <-
            cache.connectable_resources,
          resource_id = Ecto.UUID.load!(id),
          match?(
            {:ok, _resource, _membership_id, _policy_id, _expires_at},
            Cache.Client.authorize_resource(cache, device, resource_id, subject)
          ),
          into: %{},
          do: {resource_id, pool}

    for {resource_id, label} <- Core.Database.device_pool_labels(Map.keys(pools), subject),
        do: {label, Map.fetch!(pools, resource_id)}
  end

  defp reachable_through_any_pool?(socket, device) do
    pool_ids =
      for %Cache.Cacheable.Resource{type: :device_pool, id: id} <-
            socket.assigns.cache.connectable_resources,
          do: Ecto.UUID.load!(id)

    match?(
      {:ok, _resource, _membership_id, _policy_id, _expires_at},
      pick_device_pool(socket, pool_ids, device)
    )
  end
end
