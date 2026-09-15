defmodule Portal.Changes.Hooks.IntuneDevicesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.IntuneDevices
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures
  alias Portal.Changes.Change
  alias Portal.Intune
  alias Portal.PubSub

  setup do
    account = device_posture_account_fixture()
    :ok = PubSub.Changes.subscribe(account.id, :intune_devices)
    %{account: account, provider: intune_posture_provider_fixture(account: account)}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "an insert is broadcast to the account", %{provider: provider} do
    row = intune_device_fixture(provider: provider, intune_id: "mdm-1")

    assert :ok == on_insert(7, wal(row))

    assert_receive %Change{op: :insert, lsn: 7, struct: %Intune.Device{intune_id: "mdm-1"}}
  end

  test "an update is broadcast with the old and the new row", %{provider: provider} do
    row = intune_device_fixture(provider: provider, compliance_state: "compliant")

    assert :ok == on_update(8, wal(row), wal(%{row | compliance_state: "noncompliant"}))

    assert_receive %Change{
      op: :update,
      lsn: 8,
      old_struct: %Intune.Device{compliance_state: "compliant"},
      struct: %Intune.Device{compliance_state: "noncompliant"}
    }
  end

  test "a rewrite that only touched the sync bookkeeping is not published", %{provider: provider} do
    row = intune_device_fixture(provider: provider, compliance_state: "compliant")
    later = DateTime.add(DateTime.utc_now(), 3600)

    assert :ok == on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
    assert :ok == on_update(9, wal(row), wal(row))
    refute_receive %Change{}

    assert :ok == on_update(10, wal(row), wal(%{row | compliance_state: "noncompliant", synced_at: later}))
    assert_receive %Change{op: :update, lsn: 10, struct: %Intune.Device{compliance_state: "noncompliant"}}
  end

  test "a delete is broadcast to the account", %{provider: provider} do
    row = intune_device_fixture(provider: provider, intune_id: "mdm-1")

    assert :ok == on_delete(11, wal(row))

    assert_receive %Change{op: :delete, lsn: 11, old_struct: %Intune.Device{intune_id: "mdm-1"}, struct: nil}
  end
end
