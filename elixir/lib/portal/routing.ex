defmodule Portal.Routing do
  @moduledoc """
  Picks the device that serves a resource for an initiating device.

  Candidates are the online devices assigned to the resource's site, through
  any of their sites, whose protocol range overlaps the initiator's and that
  understand the resource, never the initiator itself. The receiver among
  them is the nearest, then the newest, then one at random, preferring any
  the initiator is already connected to. Every rule about who may serve what
  lives here so it has one home when it changes.
  """

  alias Portal.Cache.Cacheable
  alias Portal.Device
  alias Portal.Presence
  alias Portal.Version, as: FzVersion

  @typedoc "Where the initiator connects from, as the portal's geo lookup reported it."
  @type location :: {float() | nil, float() | nil}

  @doc """
  The online devices serving the resource's site that can serve `resource`
  for `initiator`, whose reported version is `initiator_version` when its
  connect carried no explicit protocol range.

  `{:error, :version_mismatch}` means the site has online devices but none
  compatible, which the initiator is told apart from an empty site.
  """
  @spec candidates(Cacheable.Resource.t(), Device.t(), String.t() | nil) ::
          {:ok, [Device.t()]} | {:error, :version_mismatch}
  def candidates(%Cacheable.Resource{site: site} = resource, %Device{} = initiator, initiator_version) do
    site_id = Ecto.UUID.load!(site.id)

    site_devices =
      initiator.account_id
      |> Presence.Devices.all_connected_gateways()
      |> Enum.filter(&(&1.id != initiator.id and Device.serves_site?(&1, site_id)))

    initiator_range = initiator_range(initiator, initiator_version)
    compatible = compatible_devices(site_devices, resource, initiator_version, initiator_range)

    cond do
      compatible != [] -> {:ok, compatible}
      site_devices != [] -> {:error, :version_mismatch}
      true -> {:ok, []}
    end
  end

  @doc """
  The device among `candidates` that serves this request.

  Nearest to `location` first, then the newest version, then at random. Any of
  `preferred_ids` present among the candidates are chosen over the rest, so an
  initiator keeps using a device it already has a connection to.
  """
  @spec select_receiver([Device.t()], location(), [Ecto.UUID.t()]) :: Device.t() | nil
  def select_receiver(candidates, location, preferred_ids) do
    Device.load_balance_gateways(location, candidates, preferred_ids)
  end

  @doc """
  Whether `device` can serve `resource` for an initiator on `initiator_range`.

  The two protocol ranges must overlap and the device must understand the
  resource type. An initiator with no range is compatible with everything; a
  device without a version is compatible with nothing.
  """
  @spec compatible?(Device.t(), Cacheable.Resource.t(), FzVersion.proto_range() | nil) ::
          boolean()
  def compatible?(_device, _resource, nil), do: true
  def compatible?(%Device{last_seen_version: nil}, _resource, _range), do: false

  def compatible?(%Device{last_seen_version: version} = device, resource, initiator_range) do
    device_range = device.proto_range || FzVersion.proto_range(nil, :gateway, version)

    FzVersion.compatible?(initiator_range, device_range) and
      not is_nil(Portal.Resource.adapt_resource_for_version(resource, version))
  end

  # A client that reported no version is not filtered, as before; one whose
  # version cannot be read reaches nothing.
  defp compatible_devices(devices, _resource, nil, _range), do: devices
  defp compatible_devices(_devices, _resource, _version, nil), do: []

  defp compatible_devices(devices, resource, _version, range) do
    Enum.filter(devices, &compatible?(&1, resource, range))
  end

  defp initiator_range(%Device{proto_range: range}, _version) when not is_nil(range), do: range
  defp initiator_range(_initiator, version), do: FzVersion.proto_range(nil, :client, version)
end
