defmodule Portal.Changes.Hooks.DefenderDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.DefenderDevices
  import Portal.DefenderFixtures
  import Portal.DevicePostureFixtures
  alias Portal.Changes.Change
  alias Portal.Defender
  alias Portal.PubSub

  setup do
    account = device_posture_account_fixture()
    %{account: account, provider: defender_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp listen(account, key), do: :ok = PubSub.Changes.subscribe_posture_rows(account.id, key)

  test "an insert is published under the Entra device id alone", %{account: account, provider: provider} do
    row = defender_device_fixture(provider: provider, entra_device_id: "entra-1")
    listen(account, {:entra_device_id, "entra-1"})

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %Defender.Device{entra_device_id: "entra-1"}}
    refute_receive %Change{}
  end

  test "an update is published under the old and the new Entra device id", %{account: account, provider: provider} do
    row = defender_device_fixture(provider: provider, entra_device_id: "old")
    listen(account, {:entra_device_id, "old"})
    listen(account, {:entra_device_id, "new"})

    assert :ok == on_update(8, wal(row), wal(%{row | entra_device_id: "new"}))

    assert_receive %Change{op: :update, lsn: 8, old_struct: %Defender.Device{entra_device_id: "old"}, struct: %Defender.Device{entra_device_id: "new"}}
    assert_receive %Change{op: :update, lsn: 8}
    refute_receive %Change{}
  end

  test "a rewrite that only touched the sync bookkeeping is not published", %{account: account, provider: provider} do
    row = defender_device_fixture(provider: provider, entra_device_id: "entra-1", health_status: "Active")
    listen(account, {:entra_device_id, "entra-1"})
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert :ok == on_update(9, wal(row), wal(row))
    refute_receive %Change{}

    assert :ok == on_update(10, wal(row), wal(%{row | health_status: "Inactive", synced_at: later}))
    assert_receive %Change{op: :update, lsn: 10, struct: %Defender.Device{health_status: "Inactive"}}
  end

  test "a delete is published under the row's Entra device id", %{account: account, provider: provider} do
    row = defender_device_fixture(provider: provider, entra_device_id: "entra-1")
    listen(account, {:entra_device_id, "entra-1"})

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %Defender.Device{entra_device_id: "entra-1"}, struct: nil}
  end

  test "a row without an Entra device id is published nowhere", %{account: account, provider: provider} do
    :ok = PubSub.Changes.subscribe(account.id)

    assert :ok == on_insert(1, wal(defender_device_fixture(provider: provider, entra_device_id: nil)))

    refute_receive %Change{}
  end
end
