defmodule Domain.GatewayTokenTest do
  use Domain.DataCase, async: true
  import Ecto.Changeset
  import Domain.AccountFixtures
  import Domain.SiteFixtures

  alias Domain.GatewayToken

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

  defp attrs(overrides) do
    Map.merge(%{secret_hash: "test_hash", secret_salt: "test_salt"}, overrides)
  end
end
