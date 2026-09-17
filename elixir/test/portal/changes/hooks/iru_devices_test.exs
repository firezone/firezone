defmodule Portal.Changes.Hooks.IruDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.IruDevices
  import Portal.DevicePostureFixtures
  import Portal.IruFixtures
  alias Portal.Changes.Change
  alias Portal.Iru
  alias Portal.PubSub

  setup do
    account = device_posture_account_fixture()
    :ok = PubSub.Changes.subscribe(account.id, :iru_devices)
    %{account: account, provider: iru_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "an insert is broadcast to the account", %{provider: provider} do
    row = iru_device_fixture(provider: provider, iru_id: "mdm-1")

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %Iru.Device{iru_id: "mdm-1"}}
  end

  test "an update is broadcast with the old and the new row", %{provider: provider} do
    row = iru_device_fixture(provider: provider, filevault_enabled: true)

    assert :ok == on_update(8, wal(row), wal(%{row | filevault_enabled: false}))

    assert_receive %Change{
      op: :update,
      lsn: 8,
      old_struct: %Iru.Device{filevault_enabled: true},
      struct: %Iru.Device{filevault_enabled: false}
    }
  end

  test "a rewrite that only touched the sync bookkeeping is broadcast like any other", %{provider: provider} do
    row = iru_device_fixture(provider: provider, filevault_enabled: true)
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert_receive %Change{op: :update, lsn: 9, struct: %Iru.Device{synced_at: ^later}}
  end

  test "a delete is broadcast to the account", %{provider: provider} do
    row = iru_device_fixture(provider: provider, iru_id: "mdm-1")

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %Iru.Device{iru_id: "mdm-1"}, struct: nil}
  end
end
