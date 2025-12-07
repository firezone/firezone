defmodule Domain.RelayFixtures do
  @moduledoc """
  Test helpers for creating relays and related data.
  """

  @doc """
  Generate valid relay attributes with sensible defaults.
  """
  def valid_relay_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Relay #{unique_num}",
      ipv4: {100, 64, rem(unique_num, 255), rem(unique_num, 255)},
      ipv6: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, rem(unique_num, 65535)},
      port: 3478,
      last_seen_user_agent: "Firezone-Relay/1.0.0",
      last_seen_version: "1.3.0",
      last_seen_remote_ip: {100, 64, 0, 1},
      last_seen_at: DateTime.utc_now()
    })
  end

  @doc """
  Generate a relay with valid default attributes.

  ## Examples

      relay = relay_fixture()
      relay = relay_fixture(name: "US West Relay")
      relay = relay_fixture(port: 3479)

  """
  def relay_fixture(attrs \\ %{}) do
    relay_attrs = valid_relay_attrs(attrs)

    {:ok, relay} =
      %Domain.Relay{}
      |> Domain.Relay.changeset(relay_attrs)
      |> Domain.Repo.insert()

    relay
  end

  @doc """
  Generate an online relay with last seen information.
  """
  def online_relay_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put_new(:last_seen_at, DateTime.utc_now())
      |> Map.put_new(:last_seen_user_agent, "Firezone-Relay/1.0.0")
      |> Map.put_new(:last_seen_version, "1.0.0")
      |> Map.put_new(:last_seen_remote_ip, {100, 64, 0, 1})

    relay_fixture(attrs)
  end

  @doc """
  Generate a relay with location information.
  """
  def relay_with_location_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put_new(:last_seen_remote_ip_location_region, "US-CA")
      |> Map.put_new(:last_seen_remote_ip_location_city, "San Francisco")
      |> Map.put_new(:last_seen_remote_ip_location_lat, 37.7749)
      |> Map.put_new(:last_seen_remote_ip_location_lon, -122.4194)

    relay_fixture(attrs)
  end

  @doc """
  Generate an IPv6-only relay.
  """
  def ipv6_relay_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Map.delete(:ipv4)
      |> Map.put(:ipv6, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, rem(unique_num, 65535)})

    relay_fixture(attrs)
  end

  @doc """
  Generate a dual-stack relay (both IPv4 and IPv6).
  """
  def dual_stack_relay_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Map.put_new(:ipv4, {100, 64, rem(unique_num, 255), rem(unique_num, 255)})
      |> Map.put_new(:ipv6, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, rem(unique_num, 65535)})

    relay_fixture(attrs)
  end

  @doc """
  Generate a relay with a custom port.
  """
  def relay_with_custom_port_fixture(port, attrs \\ %{}) do
    relay_fixture(Map.put(attrs, :port, port))
  end

  @doc """
  Update a relay with the given changes.
  """
  def update_relay(relay, changes) do
    relay
    |> Ecto.Changeset.change(Enum.into(changes, %{}))
    |> Domain.Repo.update!()
  end

  @doc """
  Manually disconnects a relay for testing purposes.
  This simulates the relay socket closing without token deletion.
  Used to test relay presence debouncing in client/gateway channels.
  """
  def disconnect_relay(relay) do
    :ok = Domain.Presence.untrack(self(), "presences:global_relays", relay.id)
    :ok = Domain.Presence.untrack(self(), "presences:relays:#{relay.id}", relay.id)
    :ok = Domain.PubSub.unsubscribe("relays:#{relay.id}")
    :ok
  end
end
