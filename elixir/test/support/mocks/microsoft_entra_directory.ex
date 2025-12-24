defmodule Portal.Mocks.MicrosoftEntraDirectory do
  alias Portal.Auth.Adapters.MicrosoftEntra

  def override_endpoint_url(url) do
    config = Portal.Config.fetch_env!(:domain, MicrosoftEntra.APIClient)
    config = Keyword.put(config, :endpoint, url)
    Portal.Config.put_env_override(:domain, MicrosoftEntra.APIClient, config)
  end

  def mock_users_list_endpoint(bypass, status, resp \\ nil) do
    users_list_endpoint_path = "v1.0/users"

    resp =
      resp ||
        JSON.encode!(%{
          "@odata.context" =>
            "https://graph.microsoft.com/v1.0/$metadata#users(id,displayName,userPrincipalName,mail,accountEnabled)",
          "value" => [
            %{
              "id" => "8FBDDD1B-0E73-4CD0-AD38-2ACEA67814EE",
              "displayName" => "John Doe",
              "givenName" => "John",
              "surname" => "Doe",
              "userPrincipalName" => "jdoe@example.local",
              "mail" => "jdoe@example.local",
              "accountEnabled" => true
            },
            %{
              "id" => "0B69CEE0-B884-4CAD-B7E3-DDD4D53034FB",
              "displayName" => "Jane Smith",
              "givenName" => "Jane",
              "surname" => "Smith",
              "userPrincipalName" => "jsmith@example.local",
              "mail" => "jsmith@example.local",
              "accountEnabled" => true
            },
            %{
              "id" => "84F44A7C-DC31-4B2B-83F6-6CFCF0AA2456",
              "displayName" => "Bob Smith",
              "givenName" => "Bob",
              "surname" => "Smith",
              "userPrincipalName" => "bsmith@example.local",
              "mail" => "bsmith@example.local",
              "accountEnabled" => true
            }
          ]
        })

    test_pid = self()

    Bypass.expect(bypass, "GET", users_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, status, resp)
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_groups_list_endpoint(bypass, status, resp \\ nil) do
    groups_list_endpoint_path = "v1.0/groups"

    resp =
      resp ||
        JSON.encode!(%{
          "@odata.context" => "https://graph.microsoft.com/v1.0/$metadata#groups(id,displayName)",
          "value" => [
            %{
              "id" => "962F077E-CAA2-4873-9D7D-A37CD58C06F5",
              "displayName" => "Engineering"
            },
            %{
              "id" => "AFB58E30-EB1E-4A46-913B-20C6CE476CE6",
              "displayName" => "Finance"
            },
            %{
              "id" => "01E60A9C-4EE7-4253-87D9-8677E87A0A41",
              "displayName" => "All"
            }
          ]
        })

    test_pid = self()

    Bypass.expect(bypass, "GET", groups_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, status, resp)
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_group_members_list_endpoint(bypass, group_id, status, resp \\ nil) do
    group_members_list_endpoint_path =
      "v1.0/groups/#{group_id}/transitiveMembers/microsoft.graph.user"

    memberships =
      [
        %{
          "id" => "8FBDDD1B-0E73-4CD0-AD38-2ACEA67814EE",
          "displayName" => "John Doe",
          "userPrincipalName" => "jdoe@example.local",
          "accountEnabled" => true
        },
        %{
          "id" => "0B69CEE0-B884-4CAD-B7E3-DDD4D53034FB",
          "displayName" => "Jane Smith",
          "userPrincipalName" => "jsmith@example.local",
          "accountEnabled" => true
        },
        %{
          "id" => "84F44A7C-DC31-4B2B-83F6-6CFCF0AA2456",
          "displayName" => "Bob Smith",
          "userPrincipalName" => "bsmith@example.local",
          "accountEnabled" => true
        }
      ]

    resp =
      resp ||
        JSON.encode!(%{
          "@odata.context" =>
            "https://graph.microsoft.com/v1.0/$metadata#users(id,displayName,userPrincipalName,accountEnabled)",
          "value" => memberships
        })

    test_pid = self()

    Bypass.expect(bypass, "GET", group_members_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, status, resp)
    end)

    override_endpoint_url("http://localhost:#{bypass.port}/")

    bypass
  end
end
