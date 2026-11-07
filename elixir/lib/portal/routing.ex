defmodule Portal.Routing do
  @moduledoc """
  Picks the device that serves a resource for an initiating device.

  Candidates are the online gateways in the resource's site whose version is
  compatible with the initiator's. The receiver among them is the nearest,
  then the newest, then one at random, preferring any the initiator is already
  connected to. Every rule about who may serve what lives here so it has one
  home when it changes.
  """

  alias Portal.Cache.Cacheable
  alias Portal.Device
  alias Portal.Presence

  @typedoc "Where the initiator connects from, as the portal's geo lookup reported it."
  @type location :: {float() | nil, float() | nil}

  @doc """
  The online devices in the resource's site that can serve `resource` for an
  initiator on `initiator_version`.

  `{:error, :version_mismatch}` means the site has online devices but none
  compatible, which the initiator is told apart from an empty site.
  """
  @spec candidates(Cacheable.Resource.t(), String.t() | nil, Ecto.UUID.t()) ::
          {:ok, [Device.t()]} | {:error, :version_mismatch}
  def candidates(%Cacheable.Resource{site: site} = resource, initiator_version, account_id) do
    site_id = Ecto.UUID.load!(site.id)

    site_devices =
      account_id
      |> Presence.Devices.all_connected_gateways()
      |> Enum.filter(&(&1.site_id == site_id))

    compatible = compatible_devices(site_devices, resource, initiator_version)

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
  Whether `device` on its last seen version can serve `resource` for an
  initiator on `initiator_version`.

  The device must be within one minor version of the initiator in either
  direction and must understand the resource type. An initiator with no
  version is compatible with everything; one whose version does not parse is
  compatible with nothing.
  """
  @spec compatible?(Device.t(), Cacheable.Resource.t(), String.t() | nil) :: boolean()
  def compatible?(_device, _resource, nil), do: true

  def compatible?(%Device{} = device, resource, initiator_version) do
    case Version.parse(initiator_version) do
      {:ok, version} -> compatible_version?(device, resource, version)
      :error -> false
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

  defp compatible_version?(%Device{last_seen_version: device_version} = _device, resource, version) do
    case Version.parse(device_version) do
      {:ok, parsed} ->
        Version.match?(parsed, ">= #{version.major}.#{version.minor - 1}.0") and
          Version.match?(parsed, "< #{version.major}.#{version.minor + 2}.0") and
          not is_nil(Portal.Resource.adapt_resource_for_version(resource, device_version))

      :error ->
        false
    end
  end
end
