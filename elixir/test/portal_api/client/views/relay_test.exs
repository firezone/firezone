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
    public_key = "public-key"

    [turn] = RelayView.render_many([relay], public_key, @expires_at, account_id)

    expires_at = DateTime.to_unix(@expires_at, :second)
    account = RelayView.hash_account_id(account_id)
    salt = hash(public_key)
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

    public_key = "public-key"
    [turn] = RelayView.render_many([relay], public_key, @expires_at, "account-id")

    expires_at = DateTime.to_unix(@expires_at, :second)
    salt = hash(public_key)

    assert turn.username == "#{expires_at}:#{salt}"
    assert turn.password == hash("#{expires_at}:relay-secret:#{salt}")
  end

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode64(padding: false)
  end
end
