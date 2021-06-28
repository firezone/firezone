defmodule CfHttpWeb.MockEvents do
  @moduledoc """
  A Mock module for testing external events

  XXX: This is used because CfHttp tests will launch multiple CfVpn servers.
  Instead, we should find a way to maintain a persistent link to one CfVpn server
  inside CfHttp and use that for the tests.
  """

  def create_device do
    {:ok, "privkey", "pubkey", "server_pubkey", "preshared_key"}
  end

  def delete_device(pubkey) do
    {:ok, pubkey}
  end

  def add_rule(_rule) do
    :ok
  end

  def delete_rule(_rule) do
    :ok
  end

  def set_config do
    :ok
  end

  def set_rules do
    :ok
  end
end
