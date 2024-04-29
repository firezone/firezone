defmodule Domain.Mocks.JumpCloudDirectory do
  alias Domain.Auth.Adapters.JumpCloud

  def override_endpoint_url(url) do
    config = Domain.Config.fetch_env!(:domain, JumpCloud.APIClient)
    config = Keyword.put(config, :endpoint, url)
    Domain.Config.put_env_override(:domain, JumpCloud.APIClient, config)
  end

  def mock_users_list_endpoint(bypass, users_resp \\ nil) do
    users_list_endpoint_path = "systemusers"

    resp =
      users_resp ||
        %{
          "results" => [
            %{
              "_id" => "adf766b8a6f7f315b07d707f",
              "displayname" => "",
              "email" => "johndoe@example.local",
              "firstname" => "John",
              "id" => "adf766b8a6f7f315b07d707f",
              "lastname" => "Doe",
              "organization" => "b7f554fc885d29b7432a7e8b",
              "state" => "ACTIVATED"
            },
            %{
              "_id" => "39af963a674a57ea6a50c28f",
              "displayname" => "",
              "email" => "janedoe@example.local",
              "firstname" => "Jane",
              "id" => "39af963a674a57ea6a50c28f",
              "lastname" => "Doe",
              "organization" => "b7f554fc885d29b7432a7e8b",
              "state" => "ACTIVATED"
            },
            %{
              "_id" => "f03a35386ce7792c87bc8548",
              "displayname" => "",
              "email" => "bobsmith@example.local",
              "firstname" => "Bob",
              "id" => "f03a35386ce7792c87bc8548",
              "lastname" => "Smith",
              "organization" => "b7f554fc885d29b7432a7e8b",
              "state" => "ACTIVATED"
            },
            %{
              "_id" => "4691a4969c9f2072036ca6d2",
              "displayname" => "",
              "email" => "johnsmith@example.local",
              "firstname" => "John",
              "id" => "4691a4969c9f2072036ca6d2",
              "lastname" => "Smith",
              "organization" => "b7f554fc885d29b7432a7e8b",
              "state" => "ACTIVATED"
            },
            %{
              "_id" => "2e19886addb0f0767e18108a",
              "email" => "alicesmith@example.local",
              "firstname" => "Alice",
              "id" => "2e19886addb0f0767e18108a",
              "lastname" => "Smith",
              "organization" => "b7f554fc885d29b7432a7e8b",
              "state" => "STAGED"
            }
          ],
          "totalCount" => 5
        }

    test_pid = self()

    Bypass.expect(bypass, "GET", users_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_groups_list_endpoint(bypass, groups \\ nil) do
    groups_list_endpoint_path = "v2/usergroups"

    resp =
      groups ||
        [
          %{
            "attributes" => nil,
            "description" => "All Users",
            "email" => "",
            "id" => "6337286db9bc0400013b897a",
            "memberQuery" => %{"filters" => [], "queryType" => "FilterQuery"},
            "membershipMethod" => "STATIC",
            "name" => "All Users",
            "suggestionCounts" => %{"add" => 0, "remove" => 0, "total" => 0},
            "type" => "user_group"
          },
          %{
            "attributes" => nil,
            "description" => "Finance",
            "email" => "",
            "id" => "62e72e76f2b5190a01d35395",
            "memberQuery" => %{"filters" => [], "queryType" => "FilterQuery"},
            "membershipMethod" => "STATIC",
            "name" => "Finance",
            "suggestionCounts" => %{"add" => 0, "remove" => 0, "total" => 0},
            "type" => "user_group"
          },
          %{
            "attributes" => nil,
            "description" => "Engineering",
            "email" => "",
            "id" => "6393150b2abf37800139c204",
            "memberQuery" => %{
              "filters" => ["department:$eq:engineering"],
              "queryType" => "Filter"
            },
            "membershipMethod" => "STATIC",
            "name" => "Engineering",
            "suggestionCounts" => %{"add" => 0, "remove" => 0, "total" => 0},
            "type" => "user_group"
          },
          %{
            "attributes" => nil,
            "description" => "IT",
            "email" => "",
            "id" => "6373e3d80b695b0201ce188f",
            "memberQuery" => nil,
            "membershipMethod" => "STATIC",
            "name" => "IT",
            "suggestionCounts" => %{"add" => 0, "remove" => 0, "total" => 0},
            "type" => "user_group"
          }
        ]

    test_pid = self()

    Bypass.expect(bypass, "GET", groups_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_group_members_list_endpoint(bypass, group_id, members \\ nil) do
    group_members_list_endpoint_path = "v2/usergroups/#{group_id}/members"

    resp =
      members ||
        [
          %{
            "attributes" => nil,
            "to" => %{
              "attributes" => nil,
              "id" => "adf766b8a6f7f315b07d707f",
              "type" => "user"
            }
          },
          %{
            "attributes" => nil,
            "to" => %{
              "attributes" => nil,
              "id" => "39af963a674a57ea6a50c28f",
              "type" => "user"
            }
          },
          %{
            "attributes" => nil,
            "to" => %{
              "attributes" => nil,
              "id" => "f03a35386ce7792c87bc8548",
              "type" => "user"
            }
          },
          %{
            "attributes" => nil,
            "to" => %{
              "attributes" => nil,
              "id" => "4691a4969c9f2072036ca6d2",
              "type" => "user"
            }
          }
        ]

    test_pid = self()

    Bypass.expect(bypass, "GET", group_members_list_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end
end
