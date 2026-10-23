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

  @site_payload_min_versions %{
    apple: "1.5.11",
    headless: "1.5.6",
    android: "1.5.8",
    gui: "1.5.10"
  }

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

  @typedoc """
  The protocol minors (within major 1) a device can talk to. Two devices can
  connect when their ranges overlap.
  """
  @type proto_range :: %{min: non_neg_integer(), max: non_neg_integer()}

  @doc """
  The protocol range a device speaks, from its connect parameters when it
  states one, otherwise from its version and what it was deployed as: a
  legacy client speaks exactly its own minor, a legacy gateway one minor
  either side. Those two defaults are today's rules, so nothing changes for
  the binaries in the fleet; a binary playing both roles states a range
  instead, since one version cannot satisfy both rules at once.
  """
  @spec proto_range(map() | nil, :client | :gateway, String.t() | nil) :: proto_range() | nil
  def proto_range(params, role, version)

  def proto_range(%{"proto_min" => min, "proto_max" => max}, _role, _version) do
    with {:ok, min} <- parse_minor(min),
         {:ok, max} <- parse_minor(max),
         true <- min <= max do
      %{min: min, max: max}
    else
      _ -> nil
    end
  end

  def proto_range(_params, _role, nil), do: nil

  def proto_range(_params, role, version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, %Version{major: 1, minor: minor}} -> default_range(role, minor)
      _ -> nil
    end
  end

  defp default_range(:client, minor), do: %{min: minor, max: minor}
  defp default_range(:gateway, minor), do: %{min: max(minor - 1, 0), max: minor + 1}

  defp parse_minor(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_minor(value) when is_binary(value) do
    case Integer.parse(value) do
      {minor, ""} when minor >= 0 -> {:ok, minor}
      _ -> :error
    end
  end

  defp parse_minor(_value), do: :error

  @doc "Whether two devices speak a common protocol minor."
  @spec compatible?(proto_range() | nil, proto_range() | nil) :: boolean()
  def compatible?(%{min: a_min, max: a_max}, %{min: b_min, max: b_max}) do
    a_min <= b_max and b_min <= a_max
  end

  def compatible?(_range, _other), do: false

  @doc "The range a presence meta carries, or the one its version implies."
  @spec proto_range_from_meta(map(), :client | :gateway) :: proto_range() | nil
  def proto_range_from_meta(meta, role) do
    case meta do
      %{proto_min: min, proto_max: max} when is_integer(min) and is_integer(max) ->
        %{min: min, max: max}

      _ ->
        proto_range(nil, role, Map.get(meta, :version))
    end
  end

  # Two clients can only establish a peer-to-peer connection if they share the
  # same major.minor — this lets us evolve snownet's wire format on a minor cadence
  # without breaking running deployments mid-rollout.
  def same_minor_version?(nil, _), do: false
  def same_minor_version?(_, nil), do: false

  def same_minor_version?(version_a, version_b)
      when is_binary(version_a) and is_binary(version_b) do
    with {:ok, a} <- Version.parse(version_a),
         {:ok, b} <- Version.parse(version_b) do
      a.major == b.major and a.minor == b.minor
    else
      _ -> false
    end
  end
end
