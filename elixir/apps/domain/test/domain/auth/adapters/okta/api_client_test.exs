defmodule Domain.Auth.Adapters.Okta.APIClientTest do
  use Domain.DataCase, async: true
  alias Domain.Mocks.OktaDirectory
  import Domain.Auth.Adapters.Okta.APIClient

  setup do
    jwk = %{
      "kty" => "oct",
      "k" => :jose_base64url.encode("super_secret_key")
    }

    jws = %{
      "alg" => "HS256"
    }

    claims = %{
      "sub" => "1234567890",
      "name" => "FooBar",
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "exp" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
    }

    {_, jwt} =
      JOSE.JWT.sign(jwk, jws, claims)
      |> JOSE.JWS.compact()

    account = Fixtures.Accounts.create_account()

    {provider, bypass} =
      Fixtures.Auth.start_and_create_okta_provider(
        account: account,
        access_token: jwt
      )

    %{
      account: account,
      provider: provider,
      bypass: bypass
    }
  end

  describe "list_users/1" do
    test "returns list of users", %{provider: provider, bypass: bypass} do
      OktaDirectory.mock_users_list_endpoint(bypass, 200)
      api_token = provider.adapter_state["access_token"]

      assert {:ok, users} = list_users(provider)
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

    test "returns error when Okta API is down", %{provider: provider, bypass: bypass} do
      Bypass.down(bypass)

      assert list_users(provider) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_users_list_endpoint(bypass, 201)
      assert list_users(provider) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_users_list_endpoint(bypass, 301)
      assert list_users(provider) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status", %{provider: provider, bypass: bypass} do
      OktaDirectory.mock_users_list_endpoint(
        bypass,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_users(provider) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_users_list_endpoint(bypass, 500)
      assert list_users(provider) == {:error, :retry_later}
    end

    test "returns invalid_response when api responds with unexpected data format", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_users_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"invalid" => "format"})
      )

      assert list_users(provider) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_users_list_endpoint(bypass, 200, "invalid json")

      assert {:error, %Jason.DecodeError{data: "invalid json"}} =
               list_users(provider)
    end
  end

  describe "list_groups/1" do
    test "returns list of groups", %{provider: provider, bypass: bypass} do
      OktaDirectory.mock_groups_list_endpoint(bypass, 200)
      api_token = provider.adapter_state["access_token"]

      assert {:ok, groups} = list_groups(provider)
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

    test "returns error when Okta API is down", %{provider: provider, bypass: bypass} do
      Bypass.down(bypass)

      assert list_groups(provider) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_groups_list_endpoint(bypass, 201)
      assert list_groups(provider) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_groups_list_endpoint(bypass, 301)
      assert list_groups(provider) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status", %{provider: provider, bypass: bypass} do
      OktaDirectory.mock_groups_list_endpoint(
        bypass,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_groups(provider) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_groups_list_endpoint(bypass, 500)
      assert list_groups(provider) == {:error, :retry_later}
    end

    test "returns invalid_response when api responds with unexpected data format", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_groups_list_endpoint(
        bypass,
        200,
        Jason.encode!(%{"invalid" => "format"})
      )

      assert list_groups(provider) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON", %{
      provider: provider,
      bypass: bypass
    } do
      OktaDirectory.mock_groups_list_endpoint(bypass, 200, "invalid json")

      assert {:error, %Jason.DecodeError{data: "invalid json"}} =
               list_groups(provider)
    end
  end

  describe "list_group_members/1" do
    test "returns list of group members", %{provider: provider, bypass: bypass} do
      group_id = Ecto.UUID.generate()

      OktaDirectory.mock_group_members_list_endpoint(bypass, group_id, 200)
      api_token = provider.adapter_state["access_token"]

      assert {:ok, members} = list_group_members(provider, group_id)

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

    test "returns error when Okta API is down", %{provider: provider, bypass: bypass} do
      group_id = Ecto.UUID.generate()

      Bypass.down(bypass)

      assert list_group_members(provider, group_id) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns invalid_response when api responds with unexpected 2xx status", %{
      provider: provider,
      bypass: bypass
    } do
      group_id = Ecto.UUID.generate()

      OktaDirectory.mock_group_members_list_endpoint(bypass, group_id, 201)
      assert list_group_members(provider, group_id) == {:error, :invalid_response}
    end

    test "returns invalid_response when api responds with unexpected 3xx status", %{
      provider: provider,
      bypass: bypass
    } do
      group_id = Ecto.UUID.generate()
      OktaDirectory.mock_group_members_list_endpoint(bypass, group_id, 301)
      assert list_group_members(provider, group_id) == {:error, :invalid_response}
    end

    test "returns error when api responds with 4xx status", %{provider: provider, bypass: bypass} do
      group_id = Ecto.UUID.generate()

      OktaDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        400,
        Jason.encode!(%{"error" => %{"code" => 400, "message" => "Bad Request"}})
      )

      assert list_group_members(provider, group_id) ==
               {:error, {400, %{"error" => %{"code" => 400, "message" => "Bad Request"}}}}
    end

    test "returns retry_later when api responds with 5xx status", %{
      provider: provider,
      bypass: bypass
    } do
      group_id = Ecto.UUID.generate()
      OktaDirectory.mock_group_members_list_endpoint(bypass, group_id, 500)
      assert list_group_members(provider, group_id) == {:error, :retry_later}
    end

    test "returns invalid_response when api responds with unexpected data format", %{
      provider: provider,
      bypass: bypass
    } do
      group_id = Ecto.UUID.generate()

      OktaDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        200,
        Jason.encode!(%{"invalid" => "data"})
      )

      assert list_group_members(provider, group_id) == {:error, :invalid_response}
    end

    test "returns error when api responds with invalid JSON", %{
      provider: provider,
      bypass: bypass
    } do
      group_id = Ecto.UUID.generate()

      OktaDirectory.mock_group_members_list_endpoint(
        bypass,
        group_id,
        200,
        "invalid json"
      )

      assert {:error, %Jason.DecodeError{data: "invalid json"}} =
               list_group_members(provider, group_id)
    end
  end
end
