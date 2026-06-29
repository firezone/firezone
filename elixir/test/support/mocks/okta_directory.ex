defmodule Portal.Mocks.OktaDirectory do
  import ExUnit.Assertions

  alias Portal.Okta.APIClient

  @okta_icon_md "https://ok12static.oktacdn.com/assets/img/logos/groups/odyssey/okta-medium.30ce6d4085dff29412984e4c191bc874.png"
  @okta_icon_lg "https://ok12static.oktacdn.com/assets/img/logos/groups/odyssey/okta-large.c3cb8cda8ae0add1b4fe928f5844dbe3.png"

  def mock_users_list_endpoint(status, resp \\ nil)

  def mock_users_list_endpoint(status, resp) do
    users_list_endpoint_path = "api/v1/users"

    Req.Test.expect(APIClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/" <> users_list_endpoint_path

      resp =
        resp ||
          [
          %{
            "id" => "OT6AZkcmzkDXwkXcjTHY",
            "status" => "ACTIVE",
            "created" => "2023-12-21T18:30:05.000Z",
            "activated" => nil,
            "statusChanged" => "2023-12-21T20:04:06.000Z",
            "lastLogin" => "2024-02-08T05:14:25.000Z",
            "lastUpdated" => "2023-12-21T20:04:06.000Z",
            "passwordChanged" => "2023-12-21T20:04:06.000Z",
            "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
            "profile" => %{
              "firstName" => "John",
              "lastName" => "Doe",
              "mobilePhone" => nil,
              "secondEmail" => nil,
              "login" => "jdoe@example.com",
              "email" => "jdoe@example.com"
            },
            "_links" => %{
              "self" => %{
                "href" => "#{base_url(conn)}/api/v1/users/OT6AZkcmzkDXwkXcjTHY"
              }
            }
          },
          %{
            "id" => "I5OsjUZAUVJr4BvNVp3l",
            "status" => "ACTIVE",
            "created" => "2023-10-23T18:30:05.000Z",
            "activated" => nil,
            "statusChanged" => "2023-11-21T20:04:06.000Z",
            "lastLogin" => "2024-02-02T05:14:25.000Z",
            "lastUpdated" => "2023-12-21T20:04:06.000Z",
            "passwordChanged" => "2023-12-21T20:04:06.000Z",
            "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
            "profile" => %{
              "firstName" => "Jane",
              "lastName" => "Smith",
              "mobilePhone" => nil,
              "secondEmail" => nil,
              "login" => "jsmith@example.com",
              "email" => "jsmith@example.com"
            },
            "_links" => %{
              "self" => %{
                "href" => "#{base_url(conn)}/api/v1/users/I5OsjUZAUVJr4BvNVp3l"
              }
            }
          }
        ]

      send_json_resp(conn, status, resp)
    end)

    :ok
  end

  def mock_groups_list_endpoint(status, resp \\ nil)

  def mock_groups_list_endpoint(status, resp) do
    groups_list_endpoint_path = "api/v1/groups"

    Req.Test.expect(APIClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/" <> groups_list_endpoint_path

      resp =
        resp ||
          [
          %{
            "id" => "00gezqhvv4IFj2Avg5d7",
            "created" => "2024-02-07T04:32:03.000Z",
            "lastUpdated" => "2024-02-07T04:32:03.000Z",
            "lastMembershipUpdated" => "2024-02-07T04:32:38.000Z",
            "objectClass" => [
              "okta:user_group"
            ],
            "type" => "OKTA_GROUP",
            "profile" => %{
              "name" => "DevOps",
              "description" => ""
            },
            "_links" => %{
              "logo" => [
                %{
                  "name" => "medium",
                  "href" => @okta_icon_md,
                  "type" => "image/png"
                },
                %{
                  "name" => "large",
                  "href" => @okta_icon_lg,
                  "type" => "image/png"
                }
              ],
              "users" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00gezqhvv4IFj2Avg5d7/users"
              },
              "apps" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00gezqhvv4IFj2Avg5d7/apps"
              }
            }
          },
          %{
            "id" => "00gezqfqxwa2ohLhp5d7",
            "created" => "2024-02-07T04:30:49.000Z",
            "lastUpdated" => "2024-02-07T04:30:49.000Z",
            "lastMembershipUpdated" => "2024-02-07T04:32:23.000Z",
            "objectClass" => [
              "okta:user_group"
            ],
            "type" => "OKTA_GROUP",
            "profile" => %{
              "name" => "Engineering",
              "description" => "All of Engineering"
            },
            "_links" => %{
              "logo" => [
                %{
                  "name" => "medium",
                  "href" => @okta_icon_md,
                  "type" => "image/png"
                },
                %{
                  "name" => "large",
                  "href" => @okta_icon_lg,
                  "type" => "image/png"
                }
              ],
              "users" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00gezqfqxwa2ohLhp5d7/users"
              },
              "apps" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00gezqfqxwa2ohLhp5d7/apps"
              }
            }
          },
          %{
            "id" => "00ge1rmoufwOX8isq5d7",
            "created" => "2023-12-21T18:30:00.000Z",
            "lastUpdated" => "2023-12-21T18:30:00.000Z",
            "lastMembershipUpdated" => "2024-01-05T16:16:00.000Z",
            "objectClass" => [
              "okta:user_group"
            ],
            "type" => "BUILT_IN",
            "profile" => %{
              "name" => "Everyone",
              "description" => "All users in your organization"
            },
            "_links" => %{
              "logo" => [
                %{
                  "name" => "medium",
                  "href" => @okta_icon_md,
                  "type" => "image/png"
                },
                %{
                  "name" => "large",
                  "href" => @okta_icon_lg,
                  "type" => "image/png"
                }
              ],
              "users" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00ge1rmoufwOX8isq5d7/users"
              },
              "apps" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00ge1rmoufwOX8isq5d7/apps"
              }
            }
          },
          %{
            "id" => "00ge1rmov9ULMTFSg5d7",
            "created" => "2023-12-21T18:30:01.000Z",
            "lastUpdated" => "2023-12-21T18:30:01.000Z",
            "lastMembershipUpdated" => "2023-12-21T18:30:01.000Z",
            "objectClass" => [
              "okta:user_group"
            ],
            "type" => "BUILT_IN",
            "profile" => %{
              "name" => "Okta Administrators",
              "description" =>
                "Okta manages this group, which contains all administrators in your organization."
            },
            "_links" => %{
              "logo" => [
                %{
                  "name" => "medium",
                  "href" => @okta_icon_md,
                  "type" => "image/png"
                },
                %{
                  "name" => "large",
                  "href" => @okta_icon_lg,
                  "type" => "image/png"
                }
              ],
              "users" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00ge1rmov9ULMTFSg5d7/users"
              },
              "apps" => %{
                "href" => "#{base_url(conn)}/api/v1/groups/00ge1rmov9ULMTFSg5d7/apps"
              }
            }
          }
        ]

      send_json_resp(conn, status, resp)
    end)

    :ok
  end

  def mock_group_members_list_endpoint(group_id, status, resp \\ nil)

  def mock_group_members_list_endpoint(group_id, status, resp) do
    group_members_list_endpoint_path = "api/v1/groups/#{group_id}/users"

    Req.Test.expect(APIClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/" <> group_members_list_endpoint_path

      resp =
        resp ||
          [
          %{
            "id" => "00ue1rr3zgV1DjyfL5d7",
            "status" => "ACTIVE",
            "created" => "2023-12-21T18:30:05.000Z",
            "activated" => nil,
            "statusChanged" => "2023-12-21T20:04:06.000Z",
            "lastLogin" => "2024-02-07T06:05:44.000Z",
            "lastUpdated" => "2023-12-21T20:04:06.000Z",
            "passwordChanged" => "2023-12-21T20:04:06.000Z",
            "type" => %{
              "id" => "otye1rmouoEfu7KCV5d7"
            },
            "profile" => %{
              "firstName" => "Brian",
              "lastName" => "Manifold",
              "mobilePhone" => nil,
              "secondEmail" => nil,
              "login" => "bmanifold@firezone.dev",
              "email" => "bmanifold@firezone.dev"
            },
            "credentials" => %{
              "password" => %{},
              "emails" => [
                %{
                  "value" => "bmanifold@firezone.dev",
                  "status" => "VERIFIED",
                  "type" => "PRIMARY"
                }
              ],
              "provider" => %{
                "type" => "OKTA",
                "name" => "OKTA"
              }
            },
            "_links" => %{
              "self" => %{
                "href" => "#{base_url(conn)}/api/v1/users/00ue1rr3zgV1DjyfL5d7"
              }
            }
          },
          %{
            "id" => "00ueap8xflioRLpKn5d7",
            "status" => "ACTIVE",
            "created" => "2024-01-05T16:16:00.000Z",
            "activated" => "2024-01-05T16:16:00.000Z",
            "statusChanged" => "2024-01-05T16:19:01.000Z",
            "lastLogin" => "2024-01-05T16:19:10.000Z",
            "lastUpdated" => "2024-01-05T16:19:01.000Z",
            "passwordChanged" => "2024-01-05T16:19:01.000Z",
            "type" => %{
              "id" => "otye1rmouoEfu7KCV5d7"
            },
            "profile" => %{
              "firstName" => "Brian",
              "lastName" => "Manifold",
              "mobilePhone" => nil,
              "secondEmail" => nil,
              "login" => "bmanifold@gmail.com",
              "email" => "bmanifold@gmail.com"
            },
            "credentials" => %{
              "password" => %{},
              "emails" => [
                %{
                  "value" => "bmanifold@gmail.com",
                  "status" => "VERIFIED",
                  "type" => "PRIMARY"
                }
              ],
              "provider" => %{
                "type" => "OKTA",
                "name" => "OKTA"
              }
            },
            "_links" => %{
              "self" => %{
                "href" => "#{base_url(conn)}/api/v1/users/00ueap8xflioRLpKn5d7"
              }
            }
          }
        ]

      send_json_resp(conn, status, resp)
    end)

    :ok
  end

  defp base_url(conn) do
    scheme = Atom.to_string(conn.scheme)
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"

    "#{scheme}://#{conn.host}#{port}"
  end

  defp send_json_resp(conn, status, resp) when is_binary(resp) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, resp)
  end

  defp send_json_resp(conn, status, resp) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(resp)
  end
end
