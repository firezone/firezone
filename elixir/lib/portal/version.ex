defmodule Portal.Version do
  alias Portal.{
    Client,
    ComponentVersions
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

  # TODO: Remove once all clients are on versions that support resources changing sites.
  # Connlib didn't support resources changing sites until https://github.com/firezone/firezone/pull/10604
  def resource_cannot_change_sites_on_client?(%Client{last_seen_version: version} = client) do
    case ComponentVersions.get_component_type(client) do
      :apple -> Version.compare(version, "1.5.9") == :lt
      :android -> Version.compare(version, "1.5.5") == :lt
      :headless -> Version.compare(version, "1.5.5") == :lt
      :gui -> Version.compare(version, "1.5.9") == :lt
    end
  end
end
