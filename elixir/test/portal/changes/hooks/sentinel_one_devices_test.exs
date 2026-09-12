defmodule Portal.Changes.Hooks.SentinelOneDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.SentinelOneDevices
  import Portal.DevicePostureFixtures
  import Portal.SentinelOneFixtures
  alias Portal.Changes.Change
  alias Portal.PubSub
  alias Portal.SentinelOne

  setup do
    account = device_posture_account_fixture()
    %{account: account, provider: sentinelone_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp listen(account, key), do: :ok = PubSub.Changes.subscribe_posture_rows(account.id, key)

  test "an insert is published under the serial", %{account: account, provider: provider} do
    row = sentinelone_device_fixture(provider: provider, serial_number: "SER-4")
    listen(account, {:serial, "SER-4"})

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %SentinelOne.Device{serial_number: "SER-4"}}
    refute_receive %Change{}
  end

  test "an update is published under the old and the new serial", %{account: account, provider: provider} do
    row = sentinelone_device_fixture(provider: provider, serial_number: "OLD")
    listen(account, {:serial, "OLD"})
    listen(account, {:serial, "NEW"})

    assert :ok == on_update(8, wal(row), wal(%{row | serial_number: "NEW"}))

    assert_receive %Change{op: :update, lsn: 8, old_struct: %SentinelOne.Device{serial_number: "OLD"}, struct: %SentinelOne.Device{serial_number: "NEW"}}
    assert_receive %Change{op: :update, lsn: 8}
    refute_receive %Change{}
  end

  test "a rewrite that only touched the sync bookkeeping is not published", %{account: account, provider: provider} do
    row = sentinelone_device_fixture(provider: provider, serial_number: "SER-4", computer_name: "laptop")
    listen(account, {:serial, "SER-4"})
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert :ok == on_update(9, wal(row), wal(row))
    refute_receive %Change{}

    assert :ok == on_update(10, wal(row), wal(%{row | computer_name: "renamed", synced_at: later}))
    assert_receive %Change{op: :update, lsn: 10, struct: %SentinelOne.Device{computer_name: "renamed"}}
  end

  test "a delete is published under the row's serial", %{account: account, provider: provider} do
    row = sentinelone_device_fixture(provider: provider, serial_number: "SER-4")
    listen(account, {:serial, "SER-4"})

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %SentinelOne.Device{serial_number: "SER-4"}, struct: nil}
  end

  test "nothing reaches the account-wide topic", %{account: account, provider: provider} do
    :ok = PubSub.Changes.subscribe(account.id)

    assert :ok == on_insert(1, wal(sentinelone_device_fixture(provider: provider)))

    refute_receive %Change{}
  end
end
