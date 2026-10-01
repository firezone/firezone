defmodule Portal.RelayFixtures do
  @moduledoc """
  Test helpers for creating relays and related data.
  Relays are ephemeral (not persisted to DB).
  """

  alias Portal.Relay

  @doc """
  Generate a relay with valid default attributes.
  """
  def relay_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])
    stamp_secret = attrs[:stamp_secret] || Portal.Crypto.random_token()

    %Relay{
      id: Relay.generate_id(stamp_secret),
      stamp_secret: stamp_secret,
      ipv4: attrs[:ipv4] || "100.64.#{rem(unique_num, 255)}.#{rem(unique_num, 255)}",
      ipv6: attrs[:ipv6] || "2001:db8::#{Integer.to_string(rem(unique_num, 65535), 16)}",
      port: attrs[:port] || 3478,
      lat: attrs[:lat],
      lon: attrs[:lon]
    }
  end

  @doc """
  Create a relay and connect it to presence.
  """
  def connect_relay(attrs \\ %{}) do
    relay = relay_fixture(attrs)
    :ok = Portal.Presence.Relays.connect(relay)
    relay
  end
end
