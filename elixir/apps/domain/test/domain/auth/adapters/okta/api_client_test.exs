defmodule Domain.Auth.Adapters.Okta.APIClientTest do
  use ExUnit.Case, async: true
  alias Domain.Mocks.OktaDirectory
  import Domain.Auth.Adapters.Okta.APIClient

  describe "list_users/1" do
    test "returns list of users" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      api_base_url = "http://localhost:#{bypass.port}/"
      OktaDirectory.mock_users_list_endpoint(bypass)

      assert {:ok, users} = list_users(api_base_url, api_token)
      assert length(users) == 2

      for user <- users do
        assert Map.has_key?(user, "id")
        assert Map.has_key?(user, "profile")
        assert Map.has_key?(user, "status")

        # Profile fields
        assert Map.has_key?(user["profile"], "firstName")
        assert Map.has_key?(user["profile"], "lastName")
        assert Map.has_key?(user["profile"], "email")
        assert Map.has_key?(user["profile"], "login")
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{"limit" => "200"}

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when Okta API is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      api_base_url = "http://localhost:#{bypass.port}/"
      Bypass.down(bypass)

      assert list_users(api_base_url, api_token) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "list_groups/1" do
    test "returns list of groups" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      api_base_url = "http://localhost:#{bypass.port}/"
      OktaDirectory.mock_groups_list_endpoint(bypass)

      assert {:ok, groups} = list_groups(api_base_url, api_token)
      assert length(groups) == 4

      for group <- groups do
        assert Map.has_key?(group, "id")
        assert Map.has_key?(group, "type")
        assert Map.has_key?(group, "profile")
        assert Map.has_key?(group, "_links")

        # Profile fields
        assert Map.has_key?(group["profile"], "name")
        assert Map.has_key?(group["profile"], "description")
      end

      assert_receive {:bypass_request, conn}

      assert conn.params == %{"limit" => "200"}

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when Okta API is down" do
      api_token = Ecto.UUID.generate()
      bypass = Bypass.open()
      api_base_url = "http://localhost:#{bypass.port}/"
      Bypass.down(bypass)

      assert list_groups(api_base_url, api_token) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "list_group_members/1" do
    test "returns list of group members" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()

      bypass = Bypass.open()
      api_base_url = "http://localhost:#{bypass.port}/"
      OktaDirectory.mock_group_members_list_endpoint(bypass, group_id)

      assert {:ok, members} = list_group_members(api_base_url, api_token, group_id)

      assert length(members) == 2

      for member <- members do
        assert Map.has_key?(member, "id")
        assert Map.has_key?(member, "status")
        assert Map.has_key?(member, "profile")
      end

      assert_receive {:bypass_request, conn}
      assert conn.params == %{"limit" => "200"}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{api_token}"]
    end

    test "returns error when Okta API is down" do
      api_token = Ecto.UUID.generate()
      group_id = Ecto.UUID.generate()

      bypass = Bypass.open()
      api_base_url = "http://localhost:#{bypass.port}/"
      Bypass.down(bypass)

      assert list_group_members(api_base_url, api_token, group_id) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end
end
