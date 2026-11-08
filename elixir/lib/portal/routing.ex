defmodule Portal.Routing do
  @moduledoc """
  Selects which device serves a resource, and which relays a device uses.

  Both pick the nearest candidates to a location, at random among equals.
  """

  alias Portal.Cache.Cacheable
  alias Portal.Device
  alias Portal.Geo
  alias Portal.Presence
  alias Portal.Relay
  alias Portal.Resource

  @relays_per_device 2

  @type location :: {float() | nil, float() | nil}
  @type initiator :: %{account_id: Ecto.UUID.t(), version: String.t() | nil, location: location()}

  @doc """
  The online device that serves `resource` for `initiator`.

  Only devices in the resource's site whose version is compatible with the
  initiator's are considered, and any of `preferred_ids` among them are chosen
  over the rest. Then the nearest, then the newest.
  """
  @spec select_receiver(Cacheable.Resource.t(), initiator(), [Ecto.UUID.t()]) ::
          {:ok, Device.t()} | {:error, :offline | :version_mismatch}
  def select_receiver(%Cacheable.Resource{site: site} = resource, initiator, preferred_ids) do
    site_id = Ecto.UUID.load!(site.id)

    online = Presence.Devices.connected_gateways_in_site(initiator.account_id, site_id)

    case compatible_devices(online, resource, initiator.version) do
      [] when online == [] ->
        {:error, :offline}

      [] ->
        {:error, :version_mismatch}

      compatible ->
        receiver =
          compatible
          |> prefer(preferred_ids)
          |> rank(initiator.location, &device_coordinates/1, &parse_version(&1.last_seen_version))
          |> hd()

        {:ok, receiver}
    end
  end

  @doc """
  The relays among `relays` that a device at `location` uses.
  """
  @spec select_relays([Relay.t()], location()) :: [Relay.t()]
  def select_relays(relays, location) do
    relays
    |> rank(location, &{&1.lat, &1.lon}, fn _relay -> nil end)
    |> Enum.take(@relays_per_device)
  end

  defp prefer(devices, preferred_ids) do
    case Enum.filter(devices, &(&1.id in preferred_ids)) do
      [] -> devices
      preferred -> preferred
    end
  end

  # Shuffled first and sorted stably, so equals stay in random order.
  defp rank(candidates, location, coordinates, version) do
    candidates
    |> Enum.shuffle()
    |> Enum.sort_by(version, &newer_or_equal?/2)
    |> Enum.sort_by(&distance(location, coordinates.(&1)), &nearer_or_equal?/2)
  end

  defp device_coordinates(device) do
    {device.last_seen_remote_ip_location_lat, device.last_seen_remote_ip_location_lon}
  end

  defp distance({lat, lon}, {other_lat, other_lon})
       when is_nil(lat) or is_nil(lon) or is_nil(other_lat) or is_nil(other_lon),
       do: nil

  defp distance(location, other), do: Geo.distance(location, other)

  defp nearer_or_equal?(_distance, nil), do: true
  defp nearer_or_equal?(nil, _distance), do: false
  defp nearer_or_equal?(distance, other), do: distance <= other

  defp newer_or_equal?(_version, nil), do: true
  defp newer_or_equal?(nil, _version), do: false
  defp newer_or_equal?(version, other), do: Version.compare(version, other) != :lt

  defp parse_version(nil), do: nil

  defp parse_version(version) do
    case Version.parse(version) do
      {:ok, parsed} -> parsed
      :error -> nil
    end
  end

  defp compatible_devices(devices, _resource, nil), do: devices

  defp compatible_devices(devices, resource, initiator_version) do
    case Version.parse(initiator_version) do
      {:ok, version} -> Enum.filter(devices, &compatible_version?(&1, resource, version))
      :error -> []
    end
  end

  defp compatible_version?(%Device{last_seen_version: nil}, _resource, _version), do: false

  defp compatible_version?(%Device{last_seen_version: device_version}, resource, version) do
    case Version.parse(device_version) do
      {:ok, parsed} ->
        Version.match?(parsed, ">= #{version.major}.#{version.minor - 1}.0") and
          Version.match?(parsed, "< #{version.major}.#{version.minor + 2}.0") and
          not is_nil(Resource.adapt_resource_for_version(resource, device_version))

      :error ->
        false
    end
  end
end
