defmodule Portal.Version do
  alias Portal.{
    ClientSession,
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

  def fetch_gateway_version(_user_agent) do
    {:error, :invalid_user_agent}
  end

  @site_payload_min_versions %{
    apple: "1.5.11",
    headless: "1.5.6",
    android: "1.5.8",
    gui: "1.5.10"
  }

  def client_supports_sites_payload?(%ClientSession{version: version, user_agent: user_agent})
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
  def resource_cannot_change_sites_on_client?(%ClientSession{version: nil}), do: false

  def resource_cannot_change_sites_on_client?(%ClientSession{} = session) do
    case ComponentVersions.get_component_type_from_user_agent(session.user_agent) do
      :apple -> Version.compare(session.version, "1.5.9") == :lt
      :android -> Version.compare(session.version, "1.5.5") == :lt
      :gui -> Version.compare(session.version, "1.5.9") == :lt
    end
  end

  def resource_cannot_change_sites_on_client?(%Device{
        type: :client,
        latest_session: nil
      }),
      do: false

  def resource_cannot_change_sites_on_client?(%Device{
        type: :client,
        latest_session: session
      }),
      do: resource_cannot_change_sites_on_client?(session)

  # Static device pool resources require:
  #   apple    >= 1.5.16
  #   gui      >= 1.5.13 (windows / linux gui)
  #   headless >= 1.5.9  (windows / linux headless)
  #   android  -- not yet supported
  def client_supports_static_device_pools?(%ClientSession{version: nil}), do: false

  def client_supports_static_device_pools?(%ClientSession{user_agent: nil}), do: false

  def client_supports_static_device_pools?(%ClientSession{} = session) do
    if String.contains?(session.user_agent, "headless-client/") do
      Version.compare(session.version, "1.5.9") != :lt
    else
      case ComponentVersions.get_component_type_from_user_agent(session.user_agent) do
        :apple -> Version.compare(session.version, "1.5.16") != :lt
        :gui -> Version.compare(session.version, "1.5.13") != :lt
        :android -> false
      end
    end
  end

  def client_supports_static_device_pools?(%Device{
        type: :client,
        latest_session: nil
      }),
      do: false

  def client_supports_static_device_pools?(%Device{
        type: :client,
        actor: %Portal.Actor{type: :service_account},
        latest_session: %ClientSession{version: version}
      })
      when not is_nil(version),
      do: Version.compare(version, "1.5.9") != :lt

  def client_supports_static_device_pools?(%Device{
        type: :client,
        latest_session: session
      }),
      do: client_supports_static_device_pools?(session)

  # Dynamic device pool resources require the same minimum versions as static device
  # pools: connlib's `DynamicDevicePool` resource type and `resolve_device_pool_domain`
  # message support shipped together with the device-pool ingress wire format.
  def client_supports_dynamic_device_pools?(session_or_device) do
    client_supports_static_device_pools?(session_or_device)
  end
end
