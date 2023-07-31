defmodule Domain.Mocks.GoogleWorkspaceDirectory do
  alias Domain.Auth.Adapters.GoogleWorkspace

  def override_endpoint_url(url) do
    config = Domain.Config.fetch_env!(:domain, GoogleWorkspace.APIClient)
    config = Keyword.put(config, :endpoint, url)
    Domain.Config.put_env_override(:domain, GoogleWorkspace.APIClient, config)
  end

  def mock_users_list_endpoint(bypass, users \\ nil) do
    users_list_endpoint_path = "/admin/directory/v1/users"

    resp =
      %{
        "kind" => "admin#directory#users",
        "users" =>
          users ||
            [
              %{
                "agreedToTerms" => true,
                "archived" => false,
                "changePasswordAtNextLogin" => false,
                "creationTime" => "2023-06-10T17:32:06.000Z",
                "customerId" => "CustomerID1",
                "emails" => [
                  %{"address" => "b@firez.xxx", "primary" => true},
                  %{"address" => "b@ext.firez.xxx"}
                ],
                "etag" => "\"ET-61Bnx4\"",
                "id" => "ID4",
                "includeInGlobalAddressList" => true,
                "ipWhitelisted" => false,
                "isAdmin" => false,
                "isDelegatedAdmin" => false,
                "isEnforcedIn2Sv" => false,
                "isEnrolledIn2Sv" => false,
                "isMailboxSetup" => true,
                "kind" => "admin#directory#user",
                "languages" => [%{"languageCode" => "en", "preference" => "preferred"}],
                "lastLoginTime" => "2023-06-26T13:53:30.000Z",
                "name" => %{
                  "familyName" => "Manifold",
                  "fullName" => "Brian Manifold",
                  "givenName" => "Brian"
                },
                "nonEditableAliases" => ["b@ext.firez.xxx"],
                "orgUnitPath" => "/Engineering",
                "organizations" => [
                  %{
                    "customType" => "",
                    "department" => "Engineering",
                    "location" => "",
                    "name" => "Firezone, Inc.",
                    "primary" => true,
                    "title" => "Senior Fullstack Engineer",
                    "type" => "work"
                  }
                ],
                "phones" => [%{"type" => "mobile", "value" => "(567) 111-2233"}],
                "primaryEmail" => "b@firez.xxx",
                "recoveryEmail" => "xxx@xxx.com",
                "suspended" => false,
                "thumbnailPhotoEtag" => "\"ET\"",
                "thumbnailPhotoUrl" =>
                  "https://lh3.google.com/ao/AP2z2aWvm9JM99oCFZ1TVOJgQZlmZdMMYNr7w9G0jZApdTuLHfAueGFb_XzgTvCNRhGw=s96-c"
              },
              %{
                "agreedToTerms" => true,
                "archived" => false,
                "changePasswordAtNextLogin" => false,
                "creationTime" => "2023-05-18T19:10:28.000Z",
                "customerId" => "CustomerID1",
                "emails" => [
                  %{"address" => "f@firez.xxx", "primary" => true},
                  %{"address" => "f@ext.firez.xxx"}
                ],
                "etag" => "\"ET-c\"",
                "id" => "ID104288977385815201534",
                "includeInGlobalAddressList" => true,
                "ipWhitelisted" => false,
                "isAdmin" => false,
                "isDelegatedAdmin" => false,
                "isEnforcedIn2Sv" => false,
                "isEnrolledIn2Sv" => false,
                "isMailboxSetup" => true,
                "kind" => "admin#directory#user",
                "languages" => [%{"languageCode" => "en", "preference" => "preferred"}],
                "lastLoginTime" => "2023-06-27T23:12:16.000Z",
                "name" => %{
                  "familyName" => "Lovebloom",
                  "fullName" => "Francesca Lovebloom",
                  "givenName" => "Francesca"
                },
                "nonEditableAliases" => ["f@ext.firez.xxx"],
                "orgUnitPath" => "/Engineering",
                "organizations" => [
                  %{
                    "customType" => "",
                    "department" => "Engineering",
                    "location" => "",
                    "name" => "Firezone, Inc.",
                    "primary" => true,
                    "title" => "Senior Systems Engineer",
                    "type" => "work"
                  }
                ],
                "phones" => [%{"type" => "mobile", "value" => "(567) 111-2233"}],
                "primaryEmail" => "f@firez.xxx",
                "recoveryEmail" => "xxx.xxx",
                "recoveryPhone" => "+15671112323",
                "suspended" => false
              },
              %{
                "agreedToTerms" => true,
                "archived" => false,
                "changePasswordAtNextLogin" => false,
                "creationTime" => "2022-05-31T19:17:41.000Z",
                "customerId" => "CustomerID1",
                "emails" => [
                  %{"address" => "gabriel@firez.xxx", "primary" => true},
                  %{"address" => "gabi@firez.xxx"}
                ],
                "etag" => "\"ET\"",
                "id" => "ID2",
                "includeInGlobalAddressList" => true,
                "ipWhitelisted" => false,
                "isAdmin" => false,
                "isDelegatedAdmin" => false,
                "isEnforcedIn2Sv" => false,
                "isEnrolledIn2Sv" => true,
                "isMailboxSetup" => true,
                "kind" => "admin#directory#user",
                "languages" => [%{"languageCode" => "en", "preference" => "preferred"}],
                "lastLoginTime" => "2023-07-03T17:47:37.000Z",
                "name" => %{
                  "familyName" => "Steinberg",
                  "fullName" => "Gabriel Steinberg",
                  "givenName" => "Gabriel"
                },
                "nonEditableAliases" => ["gabriel@ext.firez.xxx"],
                "orgUnitPath" => "/Engineering",
                "primaryEmail" => "gabriel@firez.xxx",
                "suspended" => false
              },
              %{
                "agreedToTerms" => true,
                "aliases" => ["jam@firez.xxx"],
                "archived" => false,
                "changePasswordAtNextLogin" => false,
                "creationTime" => "2022-04-19T21:54:21.000Z",
                "customerId" => "CustomerID1",
                "emails" => [
                  %{"address" => "j@gmail.com", "type" => "home"},
                  %{"address" => "j@firez.xxx", "primary" => true},
                  %{"address" => "j@firez.xxx"},
                  %{"address" => "j@ext.firez.xxx"}
                ],
                "etag" => "\"ET-4Z0R5TBJvppLL8\"",
                "id" => "ID1",
                "includeInGlobalAddressList" => true,
                "ipWhitelisted" => false,
                "isAdmin" => true,
                "isDelegatedAdmin" => false,
                "isEnforcedIn2Sv" => false,
                "isEnrolledIn2Sv" => true,
                "isMailboxSetup" => true,
                "kind" => "admin#directory#user",
                "languages" => [%{"languageCode" => "en", "preference" => "preferred"}],
                "lastLoginTime" => "2023-07-04T15:08:45.000Z",
                "name" => %{
                  "familyName" => "Bou Kheir",
                  "fullName" => "Jamil Bou Kheir",
                  "givenName" => "Jamil"
                },
                "nonEditableAliases" => ["jamil@ext.firez.xxx"],
                "orgUnitPath" => "/",
                "phones" => [],
                "primaryEmail" => "jamil@firez.xxx",
                "recoveryEmail" => "xxx.xxx",
                "recoveryPhone" => "+15671112323",
                "suspended" => false,
                "thumbnailPhotoEtag" => "\"ETX\"",
                "thumbnailPhotoUrl" =>
                  "https://lh3.google.com/ao/AP2z2aWvm9JM99oCFZ1TVOJgQZlmZdMMYNr7w9G0jZApdTuLHfAueGFb_XzgTvCNRhGw=s96-c"
              }
            ]
      }

    test_pid = self()

    Bypass.expect(bypass, "GET", users_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_organization_units_list_endpoint(bypass, org_units \\ nil) do
    org_units_list_endpoint_path = "/admin/directory/v1/customer/my_customer/orgunits"

    resp =
      %{
        "kind" => "admin#directory#org_units",
        "etag" => "\"FwDC5ZsOozt9qI9yuJfiMqwYO1K-EEG4flsXSov57CY/Y3F7O3B5N0h0C_3Pd3OMifRNUVc\"",
        "organizationUnits" =>
          org_units ||
            [
              %{
                "kind" => "admin#directory#orgUnit",
                "name" => "Engineering",
                "description" => "Engineering team",
                "etag" => "\"ET\"",
                "blockInheritance" => false,
                "orgUnitId" => "ID1",
                "orgUnitPath" => "/Engineering",
                "parentOrgUnitId" => "ID0",
                "parentOrgUnitPath" => "/"
              }
            ]
      }

    test_pid = self()

    Bypass.expect(bypass, "GET", org_units_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_groups_list_endpoint(bypass, groups \\ nil) do
    groups_list_endpoint_path = "/admin/directory/v1/groups"

    resp =
      %{
        "kind" => "admin#directory#groups",
        "etag" => "\"FwDC5ZsOozt9qI9yuJfiMqwYO1K-EEG4flsXSov57CY/Y3F7O3B5N0h0C_3Pd3OMifRNUVc\"",
        "groups" =>
          groups ||
            [
              %{
                "kind" => "admin#directory#group",
                "id" => "ID1",
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
              },
              %{
                "kind" => "admin#directory#group",
                "id" => "ID2",
                "etag" => "\"ET\"",
                "email" => "mktn@fiez.xxx",
                "name" => "Marketing",
                "directMembersCount" => "1",
                "description" => "Firezone Marketing team",
                "adminCreated" => true,
                "nonEditableAliases" => [
                  "mktn@ext.fiez.xxx"
                ]
              },
              %{
                "kind" => "admin#directory#group",
                "id" => "ID9c6y382yitz1j",
                "etag" => "\"ET\"",
                "email" => "sec@fiez.xxx",
                "name" => "Security",
                "directMembersCount" => "5",
                "description" => "Security Notifications",
                "adminCreated" => false,
                "nonEditableAliases" => [
                  "sec@ext.fiez.xxx"
                ]
              }
            ]
      }

    test_pid = self()

    Bypass.expect(bypass, "GET", groups_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_group_members_list_endpoint(bypass, group_id, members \\ nil) do
    group_members_list_endpoint_path = "/admin/directory/v1/groups/#{group_id}/members"

    resp =
      %{
        "kind" => "admin#directory#members",
        "etag" => "\"XXX\"",
        "members" =>
          members ||
            [
              %{
                "kind" => "admin#directory#member",
                "etag" => "\"ET\"",
                "id" => "115559319585605830228",
                "email" => "b@firez.xxx",
                "role" => "MEMBER",
                "type" => "USER",
                "status" => "ACTIVE"
              },
              %{
                "kind" => "admin#directory#member",
                "etag" => "\"ET\"",
                "id" => "115559319585605830218",
                "email" => "j@firez.xxx",
                "role" => "MEMBER",
                "type" => "USER",
                "status" => "ACTIVE"
              },
              %{
                "kind" => "admin#directory#member",
                "etag" => "\"ET\"",
                "id" => "115559319585605830518",
                "email" => "f@firez.xxx",
                "role" => "MEMBER",
                "type" => "USER",
                "status" => "INACTIVE"
              },
              %{
                "kind" => "admin#directory#member",
                "etag" => "\"ET\"",
                "id" => "02xcytpi3twf80c",
                "email" => "eng@firez.xxx",
                "role" => "MEMBER",
                "type" => "GROUP",
                "status" => "ACTIVE"
              },
              %{
                "kind" => "admin#directory#member",
                "etag" => "\"ET\"",
                "id" => "02xcytpi16r56td",
                "email" => "sec@firez.xxx",
                "role" => "MEMBER",
                "type" => "GROUP",
                "status" => "ACTIVE"
              }
            ]
      }

    test_pid = self()

    Bypass.expect(bypass, "GET", group_members_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end
end
