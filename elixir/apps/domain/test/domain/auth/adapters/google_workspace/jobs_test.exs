defmodule Domain.Auth.Adapters.GoogleWorkspace.JobsTest do
  use Domain.DataCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures}
  alias Domain.Mocks.GoogleWorkspaceDirectory
  import Domain.Auth.Adapters.GoogleWorkspace.Jobs

  describe "sync_directory/1" do
    setup do
      account = AccountsFixtures.create_account()

      {provider, bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_google_workspace_provider(account: account)

      %{
        bypass: bypass,
        account: account,
        provider: provider
      }
    end

    test "syncs IdP data", %{provider: _provider} do
      bypass = Bypass.open()

      groups = [
        %{
                "kind" => "admin#directory#group",
                "id" => "GROUP_ID1",
                "etag" => "\"ET\"",
                "email" => "i@fiez.xxx",
                "name" => "Infrastructure",
                "directMembersCount" => "5",
                "description" => "Group to handle infrastructure alerts and management",
                "adminCreated" => true,
                "aliases" => [
                  "pnr@firez.one"
                ],
                "nonEditableAliases" => [
                  "i@ext.fiez.xxx"
                ]
              }
      ]

      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, groups)
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass)
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass)
      Enum.each(groups, fn group ->
        GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, group["id"])
      end)

      assert sync_directory(%{}) == :ok
    end
  end
end
