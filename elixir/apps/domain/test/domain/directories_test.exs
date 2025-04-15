defmodule Domain.DirectoriesTest do
  use Domain.DataCase, async: true
  import Domain.Directories

  describe "fetch_provider_by_id/1" do
    test "returns the provider with the given id" do
      account = Fixtures.Accounts.create_account()
      {auth_provider, _bypass} = Fixtures.Auth.start_and_create_okta_provider(account: account)

      provider =
        Fixtures.Directories.create_okta_provider(account: account, auth_provider: auth_provider)

      provider_id = provider.id

      assert {:ok, %Domain.Directories.Provider{id: ^provider_id}} =
               fetch_provider_by_id(provider_id)
    end
  end
end
