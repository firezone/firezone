defmodule Domain.Mocks.WorkOSDirectory do
  @directory_response %{
    "id" => "dir_12345",
    "object" => "directory",
    "external_key" => "zQmqj1NkBOajdOMO",
    "state" => "linked",
    "updated_at" => "2024-05-29T15:42:30.707Z",
    "created_at" => "2024-05-29T15:42:30.707Z",
    "name" => "Foo Directory",
    "domain" => nil,
    "organization_id" => "org_12345",
    "type" => "jump cloud scim v2.0"
  }

  @directory_group_response %{
    "id" => "dir_grp_123",
    "object" => "directory_group",
    "idp_id" => "123",
    "directory_id" => "dir_123",
    "organization_id" => "org_123",
    "name" => "Foo Group",
    "created_at" => "2021-10-27 15:21:50.640958",
    "updated_at" => "2021-12-13 12:15:45.531847",
    "raw_attributes" => %{
      "foo" => "bar"
    }
  }

  @directory_user_response %{
    "id" => "user_123",
    "object" => "directory_user",
    "custom_attributes" => %{
      "custom" => true
    },
    "directory_id" => "dir_123",
    "organization_id" => "org_123",
    "emails" => [
      %{
        "primary" => true,
        "type" => "type",
        "value" => "jonsnow@workos.com"
      }
    ],
    "groups" => [@directory_group_response],
    "idp_id" => "idp_foo",
    "first_name" => "Jon",
    "last_name" => "Snow",
    "job_title" => "Knight of the Watch",
    "raw_attributes" => %{},
    "state" => "active",
    "username" => "jonsnow",
    "created_at" => "2023-07-17T20:07:20.055Z",
    "updated_at" => "2023-07-17T20:07:20.055Z"
  }

  def override_base_url(url) do
    config = Domain.Config.fetch_env!(:workos, WorkOS.Client)
    config = Keyword.put(config, :base_url, url)
    Domain.Config.put_env_override(:workos, WorkOS.Client, config)
  end

  def mock_list_directories_endpoint(bypass, directories \\ nil) do
    directories_list_endpoint_path = "/directories"
    data = directories || [@directory_response]

    resp = %{
      "data" => data,
      "list_metadata" => %{
        "before" => nil,
        "after" => nil
      }
    }

    test_pid = self()

    Bypass.expect(bypass, "GET", directories_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})

      conn
      |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
      |> Plug.Conn.send_resp(200, JSON.encode!(resp))
    end)

    bypass
  end

  def mock_list_users_endpoint(bypass, users \\ nil) do
    users_list_endpoint_path = "/directory_users"
    data = users || [@directory_user_response]

    resp = %{
      "data" => data,
      "list_metadata" => %{
        "before" => nil,
        "after" => nil
      }
    }

    test_pid = self()

    Bypass.expect(bypass, "GET", users_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})

      conn
      |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
      |> Plug.Conn.send_resp(200, JSON.encode!(resp))
    end)

    bypass
  end

  def mock_list_groups_endpoint(bypass, groups \\ nil) do
    groups_list_endpoint_path = "/directory_groups"
    data = groups || [@directory_group_response]

    resp = %{
      "data" => data,
      "list_metadata" => %{
        "before" => nil,
        "after" => nil
      }
    }

    test_pid = self()

    Bypass.expect(bypass, "GET", groups_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})

      conn
      |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
      |> Plug.Conn.send_resp(200, JSON.encode!(resp))
    end)

    bypass
  end
end
