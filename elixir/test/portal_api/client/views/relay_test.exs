defmodule PortalAPI.Client.Views.RelayTest do
  use ExUnit.Case, async: true

  alias Portal.Relay
  alias PortalAPI.Client.Views.Relay, as: RelayView

  @expires_at ~U[2038-01-01 00:00:00Z]

  test "renders account-bound credentials for Relays that support validation" do
    relay = %Relay{
      id: "relay-id",
      ipv4: "203.0.113.1",
      port: 3478,
      stamp_secret: "relay-secret",
      turn_account_validation: true
    }

    account_id = "account-id"
    device = %Portal.Device{id: "device-id", public_key: "public-key"}

    [turn] = RelayView.render_many([relay], device, @expires_at, account_id)

    expires_at = DateTime.to_unix(@expires_at, :second)
    account = RelayView.hash_account_id(account_id)
    salt = hash(device.id)
    username = "#{expires_at}:#{account}:#{salt}"

    assert turn.username == username
    assert turn.password == hash("#{username}:relay-secret")
  end

  test "keeps the legacy credential format for Relays without validation support" do
    relay = %Relay{
      id: "relay-id",
      ipv4: "203.0.113.1",
      port: 3478,
      stamp_secret: "relay-secret",
      turn_account_validation: false
    }

    device = %Portal.Device{id: "device-id", public_key: "public-key"}
    [turn] = RelayView.render_many([relay], device, @expires_at, "account-id")

    expires_at = DateTime.to_unix(@expires_at, :second)
    salt = hash(device.public_key)

    assert turn.username == "#{expires_at}:#{salt}"
    assert turn.password == hash("#{expires_at}:relay-secret:#{salt}")
  end

  test "device identity survives key rotation while credentials rotate with expiry" do
    relay = %Relay{
      id: "relay-id",
      ipv4: "203.0.113.1",
      ipv6: "2001:db8::1",
      port: 3478,
      stamp_secret: "relay-secret",
      turn_account_validation: true
    }

    device = %Portal.Device{id: "device-id", public_key: "old-key"}
    [first, ipv6] = RelayView.render_many([relay], device, @expires_at, "account-id")

    [rotated, _] =
      RelayView.render_many([relay], %{device | public_key: "new-key"}, @expires_at, "account-id")

    assert first.username == ipv6.username
    assert first.password == ipv6.password
    assert first.username == rotated.username
    assert first.password == rotated.password

    [renewed, _] =
      RelayView.render_many([relay], device, DateTime.add(@expires_at, 3600), "account-id")

    [_expiry, account, owner] = String.split(first.username, ":")
    assert [_new_expiry, ^account, ^owner] = String.split(renewed.username, ":")
    refute renewed.username == first.username
    refute renewed.password == first.password

    [other, _] =
      RelayView.render_many([relay], %{device | id: "other-device-id"}, @expires_at, "account-id")

    refute other.username == first.username
    [other_account, _] = RelayView.render_many([relay], device, @expires_at, "other-account-id")
    refute other_account.username == first.username
  end

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode64(padding: false)
  end
end
