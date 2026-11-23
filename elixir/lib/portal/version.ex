defmodule Portal.Version do
  alias Portal.{
    ComponentVersions,
    Device
  }

  def fetch_version(user_agent) when is_binary(user_agent) do
    user_agent
    |> String.split(" ")
    |> Enum.find_value(fn
      "relay/" <> version -> version
      "connlib/" <> version -> version
      "headless-client/" <> version -> version
      "gui-client/" <> version -> version
      "apple-client/" <> version -> version
      "android-client/" <> version -> version
      "gateway/" <> version -> version
      _ -> nil
    end)
    |> case do
      nil -> {:error, :invalid_user_agent}
      version -> {:ok, version}
    end
  end

  def fetch_version(_user_agent), do: {:error, :invalid_user_agent}

  # A device without a type is from a 1.7 or later binary, which supports every feature below.

  @site_payload_min_versions %{
    apple: "1.5.11",
    headless: "1.5.6",
    android: "1.5.8",
    gui: "1.5.10"
  }

  def client_supports_sites_payload?(%Device{type: nil}), do: true

  def client_supports_sites_payload?(%Device{
        type: :client,
        last_seen_version: version,
        last_seen_user_agent: user_agent
      })
      when is_binary(version) and is_binary(user_agent) do
    component = ComponentVersions.get_component_type_from_user_agent(user_agent)
    min_version = Map.fetch!(@site_payload_min_versions, component)

    case Version.parse(version) do
      {:ok, version} -> Version.compare(version, Version.parse!(min_version)) != :lt
      :error -> false
    end
  end

  def client_supports_sites_payload?(_), do: false

  # TODO: Remove once all clients are on versions that support resources changing sites.
  # Connlib didn't support resources changing sites until https://github.com/firezone/firezone/pull/10604
  def resource_cannot_change_sites_on_client?(%Device{type: nil}), do: false

  def resource_cannot_change_sites_on_client?(%Device{
        type: :client,
        last_seen_version: nil
      }),
      do: false

  def resource_cannot_change_sites_on_client?(%Device{type: :client} = client) do
    case ComponentVersions.get_component_type_from_user_agent(client.last_seen_user_agent) do
      :apple -> Version.compare(client.last_seen_version, "1.5.9") == :lt
      :android -> Version.compare(client.last_seen_version, "1.5.5") == :lt
      :gui -> Version.compare(client.last_seen_version, "1.5.9") == :lt
      :headless -> Version.compare(client.last_seen_version, "1.5.5") == :lt
    end
  end

  # Device pool resources require:
  #   apple    >= 1.5.16
  #   gui      >= 1.5.13 (windows / linux gui)
  #   headless >= 1.5.9  (windows / linux headless)
  #   android  >= 1.5.11
  def client_supports_device_pools?(%Device{type: nil}), do: true

  def client_supports_device_pools?(%Device{type: :client, last_seen_version: nil}),
    do: false

  def client_supports_device_pools?(%Device{
        type: :client,
        actor: %Portal.Actor{type: :service_account},
        last_seen_version: version
      }),
      do: Version.compare(version, "1.5.9") != :lt

  def client_supports_device_pools?(%Device{type: :client, last_seen_user_agent: nil}),
    do: false

  def client_supports_device_pools?(%Device{type: :client} = client) do
    if String.contains?(client.last_seen_user_agent, "headless-client/") do
      Version.compare(client.last_seen_version, "1.5.9") != :lt
    else
      case ComponentVersions.get_component_type_from_user_agent(client.last_seen_user_agent) do
        :apple -> Version.compare(client.last_seen_version, "1.5.16") != :lt
        :gui -> Version.compare(client.last_seen_version, "1.5.13") != :lt
        :android -> Version.compare(client.last_seen_version, "1.5.11") != :lt
      end
    end
  end

  # Receiving `client_device_access_authorized` / `client_device_access_denied` messages
  # for client-to-client connections requires:
  #   apple    >= 1.5.14
  #   gui      >= 1.5.11 (windows / linux gui)
  #   headless >= 1.5.7  (windows / linux headless)
  #   android  >= 1.5.9
  def supports_device_access?(%Device{type: nil}), do: true

  def supports_device_access?(%Device{type: :client} = client),
    do: supports_device_access?(client.last_seen_user_agent, client.last_seen_version)

  def supports_device_access?(_user_agent, nil), do: false
  def supports_device_access?(nil, _version), do: false

  def supports_device_access?(user_agent, version)
      when is_binary(user_agent) and is_binary(version) do
    case ComponentVersions.get_component_type_from_user_agent(user_agent) do
      :apple -> Version.compare(version, "1.5.14") != :lt
      :gui -> Version.compare(version, "1.5.11") != :lt
      :headless -> Version.compare(version, "1.5.7") != :lt
      :android -> Version.compare(version, "1.5.9") != :lt
    end
  end

  # Receiving `public_key_changed` requires:
  #   apple    >= 1.5.24
  #   gui      >= 1.5.21 (windows / linux gui)
  #   headless >= 1.5.16 (windows / linux headless)
  #   android  >= 1.5.18
  #   gateway  >= 1.6.5
  def supports_public_key_changed?(%Device{type: nil}), do: true
  def supports_public_key_changed?(%Device{last_seen_version: nil}), do: false

  def supports_public_key_changed?(%Device{type: :gateway, last_seen_version: version}),
    do: Version.compare(version, "1.6.5") != :lt

  def supports_public_key_changed?(%Device{type: :client, last_seen_user_agent: nil}), do: false

  def supports_public_key_changed?(%Device{type: :client} = client) do
    case ComponentVersions.get_component_type_from_user_agent(client.last_seen_user_agent) do
      :apple -> Version.compare(client.last_seen_version, "1.5.25") != :lt
      :gui -> Version.compare(client.last_seen_version, "1.5.21") != :lt
      :headless -> Version.compare(client.last_seen_version, "1.5.16") != :lt
      :android -> Version.compare(client.last_seen_version, "1.5.19") != :lt
    end
  end

  @typedoc "The protocol minors (of major 1) a device can talk to."
  @type proto_range :: %{min: non_neg_integer(), max: non_neg_integer()}

  @doc """
  The range a legacy device speaks, from its version: a client speaks exactly
  its own minor, a gateway one minor either side. These are today's rules.
  """
  @spec legacy_proto_range(:client | :gateway, String.t() | nil) :: proto_range() | nil
  def legacy_proto_range(_role, nil), do: nil

  def legacy_proto_range(role, version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, %Version{major: 1, minor: minor}} -> legacy_range(role, minor)
      _ -> nil
    end
  end

  @doc "The range a device states with `proto_min` and `proto_max`, if both are valid."
  @spec declared_proto_range(map()) :: proto_range() | nil
  def declared_proto_range(%{"proto_min" => min, "proto_max" => max}) do
    with {:ok, min} <- parse_minor(min),
         {:ok, max} <- parse_minor(max),
         true <- min <= max do
      %{min: min, max: max}
    else
      _ -> nil
    end
  end

  def declared_proto_range(_params), do: nil

  @doc "The range a presence meta carries, or the legacy range its version implies."
  @spec proto_range_from_meta(map()) :: proto_range() | nil
  def proto_range_from_meta(%{proto_min: min, proto_max: max})
      when is_integer(min) and is_integer(max),
      do: %{min: min, max: max}

  def proto_range_from_meta(meta) do
    legacy_proto_range(Map.get(meta, :type), Map.get(meta, :version))
  end

  @doc "Whether two ranges share a minor."
  @spec compatible?(proto_range() | nil, proto_range() | nil) :: boolean()
  def compatible?(%{min: a_min, max: a_max}, %{min: b_min, max: b_max}),
    do: a_min <= b_max and b_min <= a_max

  def compatible?(_range, _other), do: false

  defp legacy_range(:client, minor), do: %{min: minor, max: minor}
  defp legacy_range(:gateway, minor), do: %{min: max(minor - 1, 0), max: minor + 1}
  defp legacy_range(_role, _minor), do: nil

  defp parse_minor(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_minor(value) when is_binary(value) do
    case Integer.parse(value) do
      {minor, ""} when minor >= 0 -> {:ok, minor}
      _ -> :error
    end
  end

  defp parse_minor(_value), do: :error
end
