defmodule Portal.Changes.Hooks.DefenderDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.DefenderDevices
  import Portal.DevicePostureFixtures
  import Portal.DefenderFixtures
  alias Portal.Changes.Change
  alias Portal.Defender
  alias Portal.PubSub

  setup do
    account = device_posture_account_fixture()
    :ok = PubSub.Changes.subscribe(account.id, :defender_devices)
    %{account: account, provider: defender_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "an insert is broadcast to the account", %{provider: provider} do
    row = defender_device_fixture(provider: provider, entra_device_id: "entra-1")

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %Defender.Device{entra_device_id: "entra-1"}}
  end

  test "an update is broadcast with the old and the new row", %{provider: provider} do
    row = defender_device_fixture(provider: provider, health_status: "Active")

    assert :ok == on_update(8, wal(row), wal(%{row | health_status: "Inactive"}))

    assert_receive %Change{
      op: :update,
      lsn: 8,
      old_struct: %Defender.Device{health_status: "Active"},
      struct: %Defender.Device{health_status: "Inactive"}
    }
  end

  test "a rewrite that only touched the sync bookkeeping is not published", %{provider: provider} do
    row = defender_device_fixture(provider: provider, health_status: "Active")
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert :ok == on_update(9, wal(row), wal(row))
    refute_receive %Change{}

    assert :ok == on_update(10, wal(row), wal(%{row | health_status: "Inactive", synced_at: later}))
    assert_receive %Change{op: :update, lsn: 10, struct: %Defender.Device{health_status: "Inactive"}}
  end

  test "a delete is broadcast to the account", %{provider: provider} do
    row = defender_device_fixture(provider: provider, entra_device_id: "entra-1")

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %Defender.Device{entra_device_id: "entra-1"}, struct: nil}
  end
end
