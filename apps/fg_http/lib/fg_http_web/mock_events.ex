defmodule FgHttpWeb.MockEvents do
  @moduledoc """
  A Mock module for testing external events

  XXX: This is used because FgHttp tests will launch multiple FgVpn servers.
  Instead, we should find a way to maintain a persistent link to one FgVpn server
  inside FgHttp and use that for the tests.
  """

  def create_device_sync do
    {:ok,
     %{
       private_key: "privkey",
       public_key: "pubkey",
       server_public_key: "server_pubkey",
       preshared_key: "preshared_key"
     }}
  end
end
