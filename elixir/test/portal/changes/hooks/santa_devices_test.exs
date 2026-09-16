defmodule Portal.Changes.Hooks.SantaDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.SantaDevices
  import Portal.DevicePostureFixtures
  import Portal.SantaFixtures
  alias Portal.Changes.Change
  alias Portal.Santa
  alias Portal.PubSub

  setup do
    account = device_posture_account_fixture()
    :ok = PubSub.Changes.subscribe(account.id, :santa_devices)
    %{account: account, provider: santa_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "an insert is broadcast to the account", %{provider: provider} do
    row = santa_device_fixture(provider: provider, serial_number: "SER-1")

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %Santa.Device{serial_number: "SER-1"}}
  end

  test "an update is broadcast with the old and the new row", %{provider: provider} do
    row = santa_device_fixture(provider: provider, last_seen_client_mode: "LOCKDOWN")

    assert :ok == on_update(8, wal(row), wal(%{row | last_seen_client_mode: "MONITOR"}))

    assert_receive %Change{
      op: :update,
      lsn: 8,
      old_struct: %Santa.Device{last_seen_client_mode: "LOCKDOWN"},
      struct: %Santa.Device{last_seen_client_mode: "MONITOR"}
    }
  end

  test "a rewrite that only touched the sync bookkeeping is broadcast like any other", %{provider: provider} do
    row = santa_device_fixture(provider: provider, last_seen_client_mode: "LOCKDOWN")
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert_receive %Change{op: :update, lsn: 9, struct: %Santa.Device{synced_at: ^later}}
  end

  test "a delete is broadcast to the account", %{provider: provider} do
    row = santa_device_fixture(provider: provider, serial_number: "SER-1")

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %Santa.Device{serial_number: "SER-1"}, struct: nil}
  end
end
