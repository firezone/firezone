defmodule Portal.Changes.Hooks.SophosDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.SophosDevices
  import Portal.DevicePostureFixtures
  import Portal.SophosFixtures
  alias Portal.Changes.Change
  alias Portal.Sophos
  alias Portal.PubSub

  setup do
    account = device_posture_account_fixture()
    :ok = PubSub.Changes.subscribe(account.id, :sophos_devices)
    %{account: account, provider: sophos_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "an insert is broadcast to the account", %{provider: provider} do
    row = sophos_device_fixture(provider: provider, serial_number: "SER-1")

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %Sophos.Device{serial_number: "SER-1"}}
  end

  test "an update is broadcast with the old and the new row", %{provider: provider} do
    row = sophos_device_fixture(provider: provider, health_threats_status: "good")

    assert :ok == on_update(8, wal(row), wal(%{row | health_threats_status: "bad"}))

    assert_receive %Change{
      op: :update,
      lsn: 8,
      old_struct: %Sophos.Device{health_threats_status: "good"},
      struct: %Sophos.Device{health_threats_status: "bad"}
    }
  end

  test "a rewrite that only touched the sync bookkeeping is broadcast like any other", %{provider: provider} do
    row = sophos_device_fixture(provider: provider, health_threats_status: "good")
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert_receive %Change{op: :update, lsn: 9, struct: %Sophos.Device{synced_at: ^later}}
  end

  test "a delete is broadcast to the account", %{provider: provider} do
    row = sophos_device_fixture(provider: provider, serial_number: "SER-1")

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %Sophos.Device{serial_number: "SER-1"}, struct: nil}
  end
end
