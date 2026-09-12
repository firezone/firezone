defmodule Portal.Changes.Hooks.PostureDevicesTest do
  use Portal.DataCase, async: true

  import Portal.DefenderFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures
  import Portal.IruFixtures
  import Portal.SantaFixtures
  import Portal.SentinelOneFixtures

  alias Portal.Changes.Change
  alias Portal.Changes.Hooks
  alias Portal.PubSub

  setup do
    %{account: device_posture_account_fixture()}
  end

  # A WAL row: every column under a string key.
  defp wal(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp listen(account, key), do: :ok = PubSub.Changes.subscribe_posture_rows(account.id, key)

  describe "Intune rows" do
    test "an insert is published under the MDM id and the serial", %{account: account} do
      provider = intune_posture_provider_fixture(account: account)
      row = intune_device_fixture(provider: provider, intune_id: "mdm-1", serial_number: "SER-1")
      listen(account, {:mdm_device_id, "mdm-1"})
      listen(account, {:serial, "SER-1"})

      assert :ok == Hooks.IntuneDevices.on_insert(7, wal(row))

      assert_receive %Change{op: :insert, lsn: 7, struct: %Portal.Intune.Device{intune_id: "mdm-1"}}
      assert_receive %Change{op: :insert, lsn: 7, struct: %Portal.Intune.Device{intune_id: "mdm-1"}}
      refute_receive %Change{}
    end

    test "an update is published under the old and the new identifiers", %{account: account} do
      provider = intune_posture_provider_fixture(account: account)
      row = intune_device_fixture(provider: provider, serial_number: "OLD")
      listen(account, {:serial, "OLD"})
      listen(account, {:serial, "NEW"})

      assert :ok == Hooks.IntuneDevices.on_update(8, wal(row), wal(%{row | serial_number: "NEW"}))

      assert_receive %Change{op: :update, lsn: 8, old_struct: %{serial_number: "OLD"}, struct: %{serial_number: "NEW"}}
      assert_receive %Change{op: :update, lsn: 8}
      refute_receive %Change{}
    end

    test "a rewrite that only touched the sync bookkeeping is not published", %{account: account} do
      provider = intune_posture_provider_fixture(account: account)
      row = intune_device_fixture(provider: provider, serial_number: "SER-1")
      listen(account, {:serial, "SER-1"})
      later = DateTime.add(DateTime.utc_now(), 3600)

      assert :ok == Hooks.IntuneDevices.on_update(9, wal(row), wal(%{row | synced_at: later, updated_at: later}))
      assert :ok == Hooks.IntuneDevices.on_update(9, wal(row), wal(row))

      refute_receive %Change{}
    end

    test "a rewrite that changed telemetry is published", %{account: account} do
      provider = intune_posture_provider_fixture(account: account)
      row = intune_device_fixture(provider: provider, serial_number: "SER-1", compliance_state: "compliant")
      listen(account, {:serial, "SER-1"})
      later = DateTime.add(DateTime.utc_now(), 3600)
      changed = %{row | compliance_state: "noncompliant", synced_at: later, updated_at: later}

      assert :ok == Hooks.IntuneDevices.on_update(10, wal(row), wal(changed))

      assert_receive %Change{op: :update, lsn: 10, struct: %{compliance_state: "noncompliant"}}
    end

    test "a delete is published under the row's identifiers", %{account: account} do
      provider = intune_posture_provider_fixture(account: account)
      row = intune_device_fixture(provider: provider, intune_id: "mdm-1", serial_number: "SER-1")
      listen(account, {:mdm_device_id, "mdm-1"})

      assert :ok == Hooks.IntuneDevices.on_delete(11, wal(row))

      assert_receive %Change{op: :delete, lsn: 11, old_struct: %Portal.Intune.Device{intune_id: "mdm-1"}, struct: nil}
    end

    test "nothing reaches the account-wide topic", %{account: account} do
      :ok = PubSub.Changes.subscribe(account.id)
      row = intune_device_fixture(provider: intune_posture_provider_fixture(account: account))

      assert :ok == Hooks.IntuneDevices.on_insert(1, wal(row))

      refute_receive %Change{}
    end
  end

  describe "Defender rows" do
    test "are published under the Entra device id alone", %{account: account} do
      provider = defender_posture_provider_fixture(account: account)
      row = defender_device_fixture(provider: provider, entra_device_id: "entra-1")
      listen(account, {:entra_device_id, "entra-1"})

      assert :ok == Hooks.DefenderDevices.on_insert(1, wal(row))
      assert_receive %Change{op: :insert, struct: %Portal.Defender.Device{entra_device_id: "entra-1"}}

      assert :ok == Hooks.DefenderDevices.on_delete(2, wal(row))
      assert_receive %Change{op: :delete, old_struct: %Portal.Defender.Device{entra_device_id: "entra-1"}}
    end
  end

  describe "Iru, Santa and SentinelOne rows" do
    test "Iru rows are published under the MDM id and the serial", %{account: account} do
      provider = iru_posture_provider_fixture(account: account)
      row = iru_device_fixture(provider: provider, iru_id: "mdm-2", serial_number: "SER-2")
      listen(account, {:mdm_device_id, "mdm-2"})
      listen(account, {:serial, "SER-2"})

      assert :ok == Hooks.IruDevices.on_insert(1, wal(row))

      assert_receive %Change{op: :insert, struct: %Portal.Iru.Device{iru_id: "mdm-2"}}
      assert_receive %Change{op: :insert, struct: %Portal.Iru.Device{iru_id: "mdm-2"}}
    end

    test "Santa rows are published under the serial", %{account: account} do
      provider = santa_posture_provider_fixture(account: account)
      row = santa_device_fixture(provider: provider, serial_number: "SER-3")
      listen(account, {:serial, "SER-3"})

      assert :ok == Hooks.SantaDevices.on_update(1, wal(row), wal(%{row | hostname: "renamed"}))

      assert_receive %Change{op: :update, struct: %Portal.Santa.Device{hostname: "renamed"}}
    end

    test "SentinelOne rows are published under the serial", %{account: account} do
      provider = sentinelone_posture_provider_fixture(account: account)
      row = sentinelone_device_fixture(provider: provider, serial_number: "SER-4")
      listen(account, {:serial, "SER-4"})

      assert :ok == Hooks.SentinelOneDevices.on_delete(1, wal(row))

      assert_receive %Change{op: :delete, old_struct: %Portal.SentinelOne.Device{serial_number: "SER-4"}}
    end

    test "a row with no identifier is published nowhere", %{account: account} do
      provider = santa_posture_provider_fixture(account: account)
      row = santa_device_fixture(provider: provider, serial_number: nil)

      assert :ok == Hooks.SantaDevices.on_insert(1, wal(row))
    end
  end
end
