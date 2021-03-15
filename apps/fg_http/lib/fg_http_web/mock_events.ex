defmodule FgHttpWeb.MockEvents do
  @moduledoc """
  A Mock module for testing external events

  XXX: This is used because FgHttp tests will launch multiple FgVpn servers.
  Instead, we should find a way to maintain a persistent link to one FgVpn server
  inside FgHttp and use that for the tests.
  """

  def create_device do
    {:device_created,
     %{
       private_key: "privkey",
       public_key: "pubkey",
       server_public_key: "server_pubkey",
       preshared_key: "preshared_key"
     }}
  end

  def delete_device(pubkey) do
    {:device_deleted, pubkey}
  end

  def add_rule(_rule) do
    :rule_added
  end

  def delete_rule(_rule) do
    :rule_deleted
  end
end
