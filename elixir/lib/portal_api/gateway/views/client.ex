defmodule PortalAPI.Gateway.Views.Client do
  alias Portal.Client

  def render(%Client{} = client, preshared_key) do
    # The OS name can have spaces, hence split the user-agent step by step.
    [os_name, rest] = String.split(client.last_seen_user_agent, "/", parts: 2)
    [os_version, rest] = String.split(rest, " ", parts: 2)
    [_, rest] = String.split(rest, "/", parts: 2)

    # TODO: For easier testing, we re-parse the client version here.
    # Long term, we should not be parsing the user-agent at all in here.
    # Instead we should directly store the parsed information in the Database.
    [client_version | _] = String.split(rest, " ", parts: 2)

    # Note: We purposely omit the client_type as that will say `connlib` for older clients
    # (we've only recently changed this to `apple-client` etc).

    %{
      id: client.id,
      public_key: client.public_key,
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

  # DEPRECATED IN 1.4
  def render(%Client{} = client, client_payload, preshared_key) do
    %{
      id: client.id,
      payload: client_payload,
      peer: %{
        persistent_keepalive: 25,
        public_key: client.public_key,
        preshared_key: preshared_key,
        ipv4: client.ipv4_address.address,
        ipv6: client.ipv6_address.address
      }
    }
  end
end
