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
  Generate a relay with location information.
  """
  def relay_with_location_fixture(attrs \\ %{}) do
    attrs
    |> Map.put_new(:lat, 37.7749)
    |> Map.put_new(:lon, -122.4194)
    |> relay_fixture()
  end

  @doc """
  Generate an IPv6-only relay.
  """
  def ipv6_relay_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs
    |> Map.put(:ipv4, nil)
    |> Map.put_new(:ipv6, "2001:db8::#{Integer.to_string(rem(unique_num, 65535), 16)}")
    |> relay_fixture()
  end

  @doc """
  Generate a dual-stack relay (both IPv4 and IPv6).
  """
  def dual_stack_relay_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs
    |> Map.put_new(:ipv4, "100.64.#{rem(unique_num, 255)}.#{rem(unique_num, 255)}")
    |> Map.put_new(:ipv6, "2001:db8::#{Integer.to_string(rem(unique_num, 65535), 16)}")
    |> relay_fixture()
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
