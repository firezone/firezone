defmodule Portal.Devices.PostureTest do
  use Portal.DataCase, async: true

  import Portal.ActorFixtures
  import Portal.DefenderFixtures
  import Portal.DeviceFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures
  import Portal.IruFixtures
  import Portal.SantaFixtures
  import Portal.SentinelOneFixtures

  alias Portal.Devices.Posture

  setup do
    account = device_posture_account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    %{account: account, actor: actor}
  end

  describe "match/2" do
    test "returns nothing for a device with no identifiers", %{account: account, actor: actor} do
      intune_device_fixture(provider: intune_posture_provider_fixture(account: account))
      client = client_fixture(account: account, actor: actor, device_serial: nil)
      assert Posture.match(client) == []
    end

    test "returns nothing when the account has no providers", %{account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")
      assert Posture.match(client) == []
    end

    test "returns nothing for a gateway", %{account: account} do
      assert Posture.match(gateway_fixture(account: account)) == []
    end

    test "matches an MDM row on the attested device id first", %{account: account, actor: actor} do
      provider = intune_posture_provider_fixture(account: account)
      by_id = intune_device_fixture(provider: provider, intune_id: "mdm-1", serial_number: "OTHER")
      by_serial = intune_device_fixture(provider: provider, serial_number: "SER-1")

      client =
        client_fixture(
          account: account,
          actor: actor,
          last_attested_mdm_device_id: "mdm-1",
          last_attested_device_serial: "SER-1"
        )

      matched = Posture.match(client)
      assert {:intune, %{intune_id: "mdm-1"}, :mdm_device_id, nil} = Enum.find(matched, &(elem(&1, 1).intune_id == by_id.intune_id))
      assert {:intune, %{serial_number: "SER-1"}, :attested_serial, nil} = Enum.find(matched, &(elem(&1, 1).intune_id == by_serial.intune_id))
      assert length(matched) == 2
    end

    test "credits a self-reported serial as the weakest rung", %{account: account, actor: actor} do
      santa_device_fixture(provider: santa_posture_provider_fixture(account: account), serial_number: "SER-1")
      sentinelone_device_fixture(provider: sentinelone_posture_provider_fixture(account: account), serial_number: "SER-1")
      iru_device_fixture(provider: iru_posture_provider_fixture(account: account), serial_number: "SER-1")
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")

      matched = Posture.match(client)
      assert Enum.map(matched, &{elem(&1, 0), elem(&1, 2)}) |> Enum.sort() == [iru: :device_serial, santa: :device_serial, sentinelone: :device_serial]
    end

    test "matches Iru on its device id", %{account: account, actor: actor} do
      iru_device_fixture(provider: iru_posture_provider_fixture(account: account), iru_id: "iru-1")
      client = client_fixture(account: account, actor: actor, last_attested_mdm_device_id: "iru-1")
      assert [{:iru, %{iru_id: "iru-1"}, :mdm_device_id, nil}] = Posture.match(client)
    end

    test "reaches Defender through the matched Intune row and inherits its rung", %{account: account, actor: actor} do
      intune_device_fixture(provider: intune_posture_provider_fixture(account: account), serial_number: "SER-1", entra_device_id: "entra-1")
      defender_device_fixture(provider: defender_posture_provider_fixture(account: account), entra_device_id: "entra-1")
      defender_device_fixture(provider: defender_posture_provider_fixture(account: account), entra_device_id: "entra-2")
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")

      matched = Posture.match(client)
      assert [{:defender, %{entra_device_id: "entra-1"}, :device_serial, :intune}] = Enum.filter(matched, &(elem(&1, 0) == :defender))
    end

    test "does not reach Defender through non-Intune rows or an Intune row without an Entra id", %{account: account, actor: actor} do
      santa_device_fixture(provider: santa_posture_provider_fixture(account: account), serial_number: "SER-1")
      intune_device_fixture(provider: intune_posture_provider_fixture(account: account), serial_number: "SER-1", entra_device_id: nil)
      defender_device_fixture(provider: defender_posture_provider_fixture(account: account), entra_device_id: "entra-1")
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")

      assert Posture.match(client) |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [:intune, :santa]
    end

    test "does not reach Defender without a matched Intune row", %{account: account, actor: actor} do
      intune_posture_provider_fixture(account: account)
      defender_device_fixture(provider: defender_posture_provider_fixture(account: account), entra_device_id: "entra-1")
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")
      assert Posture.match(client) == []
    end

    test "never matches rows of another account", %{account: account, actor: actor} do
      intune_device_fixture(serial_number: "SER-1")
      intune_posture_provider_fixture(account: account)
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")
      assert Posture.match(client) == []
    end
  end

  describe "rows_by_type/2" do
    test "groups the matched rows by provider type", %{account: account, actor: actor} do
      provider = intune_posture_provider_fixture(account: account)
      intune_device_fixture(provider: provider, serial_number: "SER-1", entra_device_id: "entra-1")
      intune_device_fixture(provider: intune_posture_provider_fixture(account: account), serial_number: "SER-1")
      defender_device_fixture(provider: defender_posture_provider_fixture(account: account), entra_device_id: "entra-1")
      client = client_fixture(account: account, actor: actor, device_serial: "SER-1")

      rows = Posture.rows_by_type(client)
      assert Map.keys(rows) |> Enum.sort() == [:defender, :intune]
      assert length(rows.intune) == 2
      assert [%Portal.Defender.Device{}] = rows.defender
    end

    test "is empty when nothing matched", %{account: account, actor: actor} do
      client = client_fixture(account: account, actor: actor)
      assert Posture.rows_by_type(client) == %{}
    end
  end

  test "rung_rank/1 orders the ladder" do
    assert Enum.map([:mdm_device_id, :attested_serial, :device_serial], &Posture.rung_rank/1) == [0, 1, 2]
  end

  test "schema/1 and rung_fields/2 cover every provider type" do
    for type <- [:intune, :iru, :defender, :santa, :sentinelone] do
      assert Posture.schema(type).__schema__(:source) =~ "devices"
      assert is_list(Posture.rung_fields(type, :mdm_device_id))
      assert is_list(Posture.rung_fields(type, :attested_serial))
    end
  end
end
