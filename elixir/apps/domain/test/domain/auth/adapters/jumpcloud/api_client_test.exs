defmodule Domain.Auth.Adapters.JumpCloud.APIClientTest do
  use ExUnit.Case, async: true
  alias Domain.Mocks.JumpCloudDirectory
  import Domain.Auth.Adapters.JumpCloud.APIClient

  describe "list_users/1" do
    test "returns list of users" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      JumpCloudDirectory.mock_users_list_endpoint(bypass)
      assert {:ok, users} = list_users(api_token)

      assert length(users) == 4

      for user <- users do
        assert Map.has_key?(user, "id")

        # Profile fields
        assert Map.has_key?(user, "displayname")
        assert Map.has_key?(user, "firstname")
        assert Map.has_key?(user, "lastname")
        assert Map.has_key?(user, "email")
        assert Map.has_key?(user, "organization")
        assert Map.has_key?(user, "state")
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{
               "fields" => "id email firstname lastname state organization displayname",
               "limit" => "100",
               "skip" => "0",
               "sort" => "id"
             }

      assert Plug.Conn.get_req_header(conn, "x-api-key") == [api_token]
    end

    test "returns error when JumpCloud API is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      JumpCloudDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)
      assert list_users(api_token) == {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "list_groups/1" do
    test "returns list of groups" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      JumpCloudDirectory.mock_groups_list_endpoint(bypass)
      assert {:ok, groups} = list_groups(api_token)

      assert length(groups) == 4

      for group <- groups do
        assert Map.has_key?(group, "attributes")
        assert Map.has_key?(group, "description")
        assert Map.has_key?(group, "email")
        assert Map.has_key?(group, "id")
        assert Map.has_key?(group, "memberQuery")
        assert Map.has_key?(group, "membershipMethod")
        assert Map.has_key?(group, "name")
        assert Map.has_key?(group, "type")
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{
               "fields" =>
                 "attributes,description,email,id,memberQuery,membershipMethod,name,type",
               "limit" => "100",
               "skip" => "0",
               "sort" => "name"
             }

      assert Plug.Conn.get_req_header(conn, "x-api-key") == [api_token]
    end

    test "returns error when JumpCloud API is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      JumpCloudDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)
      assert list_groups(api_token) == {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "list_group_members/1" do
    test "returns list of group members" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()

      bypass = Bypass.open()
      JumpCloudDirectory.mock_users_list_endpoint(bypass)
      JumpCloudDirectory.mock_group_members_list_endpoint(bypass, group_id)

      assert {:ok, users} = list_users(api_token)
      user_ids = MapSet.new(users, & &1["id"])

      assert {:ok, members} = list_group_members(api_token, group_id, user_ids)

      assert length(members) == 4

      for member <- members do
        assert MapSet.member?(user_ids, member)
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{
               "fields" => "id email firstname lastname state organization displayname",
               "limit" => "100",
               "skip" => "0",
               "sort" => "id"
             }

      assert Plug.Conn.get_req_header(conn, "x-api-key") == [api_token]
    end

    test "returns error when JumpCloud API is down" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()

      bypass = Bypass.open()
      JumpCloudDirectory.override_endpoint_url("http://localhost:#{bypass.port}/")
      Bypass.down(bypass)

      assert list_group_members(api_token, group_id, MapSet.new([])) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end
end
