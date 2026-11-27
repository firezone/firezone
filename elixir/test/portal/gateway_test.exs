defmodule Portal.GatewayTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Ecto.Query
  import Portal.DeviceFixtures

  alias Portal.Device

  defp build_changeset(attrs) do
    %Device{type: :gateway}
    |> cast(attrs, [:name, :firezone_id])
    |> Device.changeset()
  end

  describe "changeset/1 basic validations" do
    test "does not require firezone_id" do
      # Gateways are pre-created via the API/dashboard and only get a
      # firezone_id once they first connect and report one - unlike
      # clients, which always have one from creation.
      changeset = build_changeset(%{name: "Gateway"})
      refute Map.has_key?(errors_on(changeset), :firezone_id)
    end

    test "inserts name at maximum length" do
      gateway = gateway_fixture(name: String.duplicate("a", 255))
      assert String.length(gateway.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "rejects firezone_id exceeding maximum length" do
      changeset = build_changeset(%{name: "Gateway", firezone_id: String.duplicate("a", 256)})
      assert %{firezone_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "bounds device identifiers like any other device" do
      changeset =
        %Device{type: :gateway}
        |> cast(
          %{name: "Gateway", identifier_for_vendor: String.duplicate("a", 256)},
          [:name, :identifier_for_vendor]
        )
        |> Device.changeset()

      assert %{identifier_for_vendor: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "cannot be verified" do
      changeset =
        %Device{type: :gateway}
        |> cast(%{name: "Gateway", verified_at: DateTime.utc_now()}, [:name, :verified_at])
        |> Device.changeset()

      assert %{verified_at: ["can only be set for client devices"]} = errors_on(changeset)
    end
  end

  describe "changeset/1 firezone_id uniqueness" do
    setup do
      account = Portal.AccountFixtures.account_fixture()
      %{account: account, gateway: gateway_fixture(account: account)}
    end

    test "rejects a firezone_id another gateway in the account holds", %{
      account: account,
      gateway: gateway
    } do
      other = gateway_fixture(account: account)

      assert {:error, changeset} = update_firezone_id(other, gateway.firezone_id)
      assert %{firezone_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "accepts a firezone_id an exempt gateway holds", %{account: account, gateway: gateway} do
      other = gateway_fixture(account: account)

      Repo.update_all(
        from(d in "devices", where: d.id == type(^gateway.id, Ecto.UUID)),
        set: [firezone_id_exempt: true]
      )

      assert {:ok, _gateway} = update_firezone_id(other, gateway.firezone_id)
    end

    test "accepts a firezone_id a gateway in another account holds", %{gateway: gateway} do
      assert {:ok, _gateway} = update_firezone_id(gateway_fixture(), gateway.firezone_id)
    end
  end

  describe "device key" do
    setup do
      account = Portal.AccountFixtures.account_fixture()
      %{account: account, gateway: gateway_fixture(account: account)}
    end

    test "lets gateways with a key share a firezone_id", %{account: account, gateway: gateway} do
      Repo.update_all(from(d in Device, where: d.id == ^gateway.id), set: [key_hash: key_hash()])
      other = gateway_fixture(account: account)

      assert {:ok, _gateway} = update_firezone_id(other, gateway.firezone_id)
    end

    test "gives each key one device in the account", %{account: account, gateway: gateway} do
      key_hash = key_hash()
      Repo.update_all(from(d in Device, where: d.id == ^gateway.id), set: [key_hash: key_hash])

      assert {:error, changeset} =
               gateway_fixture(account: account)
               |> change(key_hash: key_hash)
               |> Device.changeset()
               |> Repo.update()

      assert %{key_hash: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, _gateway} =
               gateway_fixture() |> change(key_hash: key_hash) |> Device.changeset() |> Repo.update()
    end

    test "keeps the device when the actor that enrolled it is deleted", %{account: account, gateway: gateway} do
      actor = Portal.ActorFixtures.actor_fixture(account: account)

      Repo.update_all(from(d in Device, where: d.id == ^gateway.id),
        set: [enrolled_by_actor_id: actor.id, enrolled_at: DateTime.utc_now()]
      )

      Repo.delete!(actor)

      assert %Device{enrolled_by_actor_id: nil} = Repo.get_by!(Device, id: gateway.id)
    end
  end

  defp key_hash, do: :crypto.strong_rand_bytes(32)

  defp update_firezone_id(gateway, firezone_id) do
    gateway
    |> change(firezone_id: firezone_id)
    |> Device.changeset()
    |> Repo.update()
  end
end
