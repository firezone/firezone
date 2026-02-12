defmodule PortalAPI.Gateway.Views.Client do
  alias Portal.Client

  def render(%Client{} = client, public_key, preshared_key, user_agent) do
    {os_name, os_version, client_version} = parse_user_agent(user_agent)

    %{
      id: client.id,
      public_key: public_key,
      preshared_key: preshared_key,
      ipv4: client.ipv4_address.address,
      ipv6: client.ipv6_address.address,
      version: client_version,
      device_serial: client.device_serial,
      device_os_name: os_name,
      device_os_version: os_version,
      device_uuid: client.device_uuid,
      firebase_installation_id: client.firebase_installation_id,
      identifier_for_vendor: client.identifier_for_vendor
    }
  end

  # The OS name can have spaces, hence split the user-agent step by step.
  # Expected format: "OS/version connlib/version ..."
  defp parse_user_agent(user_agent) do
    with [os_name, rest] when rest != "" <- String.split(user_agent, "/", parts: 2),
         [os_version, rest] when rest != "" <- String.split(rest, " ", parts: 2),
         [_, rest] when rest != "" <- String.split(rest, "/", parts: 2) do
      [client_version | _] = String.split(rest, " ", parts: 2)
      {os_name, os_version, client_version}
    else
      _ -> {user_agent, nil, nil}
    end
  end

  # DEPRECATED IN 1.4
  def render_legacy(%Client{} = client, public_key, client_payload, preshared_key) do
    %{
      id: client.id,
      payload: client_payload,
      peer: %{
        persistent_keepalive: 25,
        public_key: public_key,
        preshared_key: preshared_key,
        ipv4: client.ipv4_address.address,
        ipv6: client.ipv6_address.address
      }
    }
  end
end
