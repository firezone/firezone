defmodule Portal.GatewayTokenTest do
  use Portal.DataCase, async: true
  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures

  alias Portal.GatewayToken

  describe "changeset/1" do
    test "returns error when account_id does not match site's account" do
      site = site_fixture()
      attrs = attrs(%{account_id: Ecto.UUID.generate(), site_id: site.id})

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)

      # The composite FK (account_id, site_id) -> sites(account_id, id) ensures
      # the account_id must match the site's account
      assert {:site, {"does not exist", _}} = hd(changeset.errors)
    end

    test "returns error when site does not exist" do
      account = account_fixture()
      attrs = attrs(%{account_id: account.id, site_id: Ecto.UUID.generate()})

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert {:site, {"does not exist", _}} = hd(changeset.errors)
    end

    test "inserts successfully with valid associations" do
      site = site_fixture()
      attrs = attrs(%{account_id: site.account_id, site_id: site.id})

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:ok, token} = Repo.insert(changeset)
      assert token.account_id == site.account_id
      assert token.site_id == site.id
    end
  end

  describe "single-owner tokens" do
    test "inserts successfully with device_id and no site_id" do
      gateway = gateway_fixture()
      attrs = attrs(%{account_id: gateway.account_id, device_id: gateway.id})

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:ok, token} = Repo.insert(changeset)
      assert token.device_id == gateway.id
      assert is_nil(token.site_id)
      assert GatewayToken.single_owner?(token)
    end

    test "returns error when both site_id and device_id are set" do
      gateway = gateway_fixture()

      attrs =
        attrs(%{
          account_id: gateway.account_id,
          site_id: gateway.site_id,
          device_id: gateway.id
        })

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert {:site_id, {"is invalid", _}} = hd(changeset.errors)
    end

    test "returns error when neither site_id nor device_id is set" do
      account = account_fixture()
      attrs = attrs(%{account_id: account.id})

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert {:site_id, {"is invalid", _}} = hd(changeset.errors)
    end

    test "returns error when account_id does not match device's account" do
      gateway = gateway_fixture()
      attrs = attrs(%{account_id: account_fixture().id, device_id: gateway.id})

      changeset =
        %GatewayToken{}
        |> change(attrs)
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert {:device, {"does not exist", _}} = hd(changeset.errors)
    end

    test "rejects a second active token for the same gateway" do
      gateway = gateway_fixture()
      insert_token!(gateway)

      changeset =
        %GatewayToken{}
        |> change(attrs(%{account_id: gateway.account_id, device_id: gateway.id}))
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert {:device_id, {"has already been taken", _}} = hd(changeset.errors)
    end

    test "allows one active and one rotated token for the same gateway" do
      gateway = gateway_fixture()
      insert_token!(gateway, rotated_at: DateTime.utc_now())

      changeset =
        %GatewayToken{}
        |> change(attrs(%{account_id: gateway.account_id, device_id: gateway.id}))
        |> GatewayToken.changeset()

      assert {:ok, _active_token} = Repo.insert(changeset)
    end

    test "rejects a second rotated token for the same gateway" do
      gateway = gateway_fixture()
      insert_token!(gateway, rotated_at: DateTime.utc_now())

      changeset =
        %GatewayToken{}
        |> change(
          attrs(%{
            account_id: gateway.account_id,
            device_id: gateway.id,
            rotated_at: DateTime.utc_now()
          })
        )
        |> GatewayToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert {:device_id, {"has already been taken", _}} = hd(changeset.errors)
    end

    test "deleting the gateway cascades to its tokens" do
      gateway = gateway_fixture()
      token = insert_token!(gateway)

      Repo.delete!(gateway)

      refute Repo.get_by(GatewayToken, account_id: token.account_id, id: token.id)
    end

    test "tokens for different gateways do not conflict" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway_1 = gateway_fixture(account: account, site: site)
      gateway_2 = gateway_fixture(account: account, site: site)

      assert insert_token!(gateway_1)
      assert insert_token!(gateway_2)
    end

    test "multi-owner tokens for the same site are unaffected by the device index" do
      site = site_fixture()

      for _ <- 1..2 do
        changeset =
          %GatewayToken{}
          |> change(attrs(%{account_id: site.account_id, site_id: site.id}))
          |> GatewayToken.changeset()

        assert {:ok, _token} = Repo.insert(changeset)
      end
    end
  end

  describe "device pre-creation" do
    test "a gateway device can be inserted without a firezone_id" do
      site = site_fixture()

      device =
        Repo.insert!(%Portal.Device{
          account_id: site.account_id,
          site_id: site.id,
          type: :gateway,
          name: "pre-created",
          firezone_id: nil
        })

      assert is_nil(device.firezone_id)
    end
  end

  defp insert_token!(gateway, overrides \\ []) do
    attrs =
      Map.merge(
        %{account_id: gateway.account_id, device_id: gateway.id},
        Map.new(overrides)
      )

    %GatewayToken{}
    |> change(attrs(attrs))
    |> GatewayToken.changeset()
    |> Repo.insert!()
  end

  defp attrs(overrides) do
    Map.merge(%{secret_hash: "test_hash", secret_salt: "test_salt"}, overrides)
  end
end
