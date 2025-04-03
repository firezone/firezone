defmodule Domain.Auth.Adapters.GoogleWorkspace.APIClientTest do
  use ExUnit.Case, async: true
  alias Domain.Mocks.GoogleWorkspaceDirectory
  import Domain.Auth.Adapters.GoogleWorkspace.APIClient

  describe "list_users/1" do
    test "returns list of users" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, 200)
      assert {:ok, users} = list_users(api_token)

      assert length(users) == 4

      for user <- users do
        assert Map.has_key?(user, "id")

        # Profile fields
        assert Map.has_key?(user, "primaryEmail")
        assert Map.has_key?(user["name"], "fullName")

        # Group fields
        assert Map.has_key?(user, "orgUnitPath")

        # Policy fields
        assert Map.has_key?(user, "creationTime")
        assert Map.has_key?(user, "isEnforcedIn2Sv")
        assert Map.has_key?(user, "isEnrolledIn2Sv")
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{
               "customer" => "my_customer",
               "query" => "isSuspended=false isArchived=false",
               "showDeleted" => "false",
               "maxResults" => "350"
             }

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when google api is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)
      assert list_users(api_token) == {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, 201)
      assert list_users(api_token) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, 301)
      assert list_users(api_token) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_users(api_token) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, 500)
      assert list_users(api_token) == {:error, :retry_later}
    end

    test "returns invalid_response when api responds without expected JSON keys" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{})
      )

      assert list_users(api_token) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected data format" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"users" => "invalid data"})
      )

      assert list_users(api_token) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_users_list_endpoint(bypass, 200, "invalid json")
      assert {:error, %Jason.DecodeError{data: "invalid json"}} = list_users(api_token)
    end
  end

  describe "list_organization_units/1" do
    test "returns list of organization units" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, 200)
      assert {:ok, organization_units} = list_organization_units(api_token)

      assert length(organization_units) == 1

      for organization_unit <- organization_units do
        assert Map.has_key?(organization_unit, "orgUnitPath")
        assert Map.has_key?(organization_unit, "orgUnitId")
        assert Map.has_key?(organization_unit, "name")
      end

      assert_receive {:bypass_request, conn}
      assert conn.params == %{"maxResults" => "350", "type" => "ALL"}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when google api is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)

      assert list_organization_units(api_token) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, 201)
      assert list_organization_units(api_token) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, 301)
      assert list_organization_units(api_token) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_organization_units(api_token) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, 500)
      assert list_organization_units(api_token) == {:error, :retry_later}
    end

    test "returns invalid_response when api responds without expected JSON keys" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{})
      )

      assert list_organization_units(api_token) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected data format" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"organization_units" => "invalid data"})
      )

      assert list_organization_units(api_token) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_organization_units_list_endpoint(bypass, 200, "invalid json")

      assert {:error, %Jason.DecodeError{data: "invalid json"}} =
               list_organization_units(api_token)
    end
  end

  describe "list_groups/1" do
    test "returns list of groups" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, 200)
      assert {:ok, groups} = list_groups(api_token)

      assert length(groups) == 3

      for group <- groups do
        assert Map.has_key?(group, "id")
        assert Map.has_key?(group, "name")
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{
               "customer" => "my_customer",
               "maxResults" => "350"
             }

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when google api is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)
      assert list_groups(api_token) == {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, 201)
      assert list_groups(api_token) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, 301)
      assert list_groups(api_token) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_groups(api_token) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, 500)
      assert list_groups(api_token) == {:error, :retry_later}
    end

    test "returns invalid_response when api responds without expected JSON keys" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{})
      )

      assert list_groups(api_token) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected data format" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"groups" => "invalid data"})
      )

      assert list_groups(api_token) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_groups_list_endpoint(bypass, 200, "invalid json")
      assert {:error, %Jason.DecodeError{data: "invalid json"}} = list_groups(api_token)
    end
  end

  describe "list_group_members/1" do
    test "returns list of group members" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()

      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, group_id, 200)
      assert {:ok, members} = list_group_members(api_token, group_id)

      assert length(members) == 2

      for member <- members do
        assert Map.has_key?(member, "id")
        assert Map.has_key?(member, "email")
      end

      assert_receive {:bypass_request, conn}
      assert conn.params == %{"includeDerivedMembership" => "true", "maxResults" => "350"}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when google api is down" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()

      bypass = Bypass.open()
      GoogleWorkspaceDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)

      assert list_group_members(api_token, group_id) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, group_id, 201)
      assert list_group_members(api_token, group_id) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, group_id, 301)
      assert list_group_members(api_token, group_id) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_group_members(api_token, group_id) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()
      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(bypass, group_id, 500)
      assert list_group_members(api_token, group_id) == {:error, :retry_later}
    end

    # Google often omits the "members" key if there are no members in the group
    test "returns empty list when api responds without expected JSON keys" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        200,
        Jason.encode!(%{})
      )

      assert list_group_members(api_token, group_id) == {:ok, []}
    end

    test "returns invalid_response when api responds with unexpected data format" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        200,
        Jason.encode!(%{"members" => "invalid data"})
      )

      assert list_group_members(api_token, group_id) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()
      bypass = Bypass.open()

      GoogleWorkspaceDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        200,
        "invalid json"
      )

      assert {:error, %Jason.DecodeError{data: "invalid json"}} =
               list_group_members(api_token, group_id)
    end
  end
end
