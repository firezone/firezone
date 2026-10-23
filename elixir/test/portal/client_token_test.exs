defmodule Portal.ClientTokenTest do
  use Portal.DataCase, async: true
  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.ClientToken

  describe "bound tokens" do
    setup do
      account = account_fixture()
      actor = service_account_fixture(account: account)
      device = client_fixture(account: account, actor: actor)
      %{account: account, actor: actor, device: device}
    end

    test "bind to one device and need no expiry", %{account: account, actor: actor, device: device} do
      token = client_token_fixture(account: account, actor: actor, device: device, expires_at: nil)

      assert token.device_id == device.id
      assert is_nil(token.expires_at)
      assert ClientToken.bound?(token)
    end

    test "are deleted with their device", %{account: account, actor: actor, device: device} do
      token = client_token_fixture(account: account, actor: actor, device: device)

      Repo.delete!(device)

      refute Repo.get_by(ClientToken, id: token.id)
    end

    test "allow one active and one rotated token per device", %{
      account: account,
      actor: actor,
      device: device
    } do
      client_token_fixture(account: account, actor: actor, device: device)

      client_token_fixture(
        account: account,
        actor: actor,
        device: device,
        rotated_at: DateTime.utc_now()
      )

      assert_raise Ecto.InvalidChangesetError, ~r/device_id/, fn ->
        client_token_fixture(account: account, actor: actor, device: device)
      end
    end

    test "cannot also join a site", %{account: account, actor: actor, device: device} do
      site = site_fixture(account: account)

      changeset =
        %ClientToken{account_id: account.id, actor_id: actor.id}
        |> change(%{
          device_id: device.id,
          site_id: site.id,
          secret_salt: "salt",
          secret_hash: "hash"
        })
        |> ClientToken.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{device_id: [_]} = errors_on(changeset)
    end
  end

  describe "joining tokens" do
    test "name the site a device created on first connect is assigned to" do
      account = account_fixture()
      actor = service_account_fixture(account: account)
      site = site_fixture(account: account)

      token = client_token_fixture(account: account, actor: actor, site: site)

      assert token.site_id == site.id
      refute ClientToken.bound?(token)

      Repo.delete!(site)
      refute Repo.get_by(ClientToken, id: token.id)
    end
  end

  describe "ordinary tokens" do
    test "are neither bound nor joining" do
      token = client_token_fixture()

      assert is_nil(token.device_id)
      assert is_nil(token.site_id)
      assert is_nil(token.rotated_at)
      refute ClientToken.bound?(token)
    end
  end
end
