defmodule PortalAPI.ClientTokenControllerTest do
  use PortalAPI.ConnCase, async: true

  alias Portal.ClientToken

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      service_account = service_account_fixture(account: account)
      conn = get(conn, "/actors/#{service_account.id}/client_tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists client token metadata for a service account", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      tokens = for _ <- 1..3, do: client_token_fixture(account: account, actor: service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{service_account.id}/client_tokens")

      assert %{
               "data" => data,
               "metadata" => %{"count" => 3, "limit" => 50}
             } = json_response(conn, 200)

      data_ids = Enum.map(data, & &1["id"])
      token_ids = Enum.map(tokens, & &1.id)
      assert equal_ids?(data_ids, token_ids)

      Enum.each(data, fn token ->
        assert is_binary(token["actor_id"])
        assert is_binary(token["expires_at"])
        assert is_binary(token["inserted_at"])
        assert is_binary(token["updated_at"])
        refute Map.has_key?(token, "token")
      end)
    end

    test "lists client token metadata for an account_user", %{conn: conn, account: account, actor: actor} do
      user_actor = actor_fixture(account: account, type: :account_user)
      created_tokens = for _ <- 1..3, do: client_token_fixture(account: account, actor: user_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{user_actor.id}/client_tokens")

      assert %{
               "data" => data,
               "metadata" => %{"count" => 3, "limit" => 50}
             } = json_response(conn, 200)

      response_token_ids = Enum.map(data, & &1["id"])
      created_token_ids = Enum.map(created_tokens, & &1.id)
      assert equal_ids?(response_token_ids, created_token_ids)

      Enum.each(data, fn token ->
        assert is_binary(token["actor_id"])
        assert is_binary(token["expires_at"])
        assert is_binary(token["inserted_at"])
        assert is_binary(token["updated_at"])
        refute Map.has_key?(token, "token")
      end)
    end

    test "lists client token metadata for an account_admin_user", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      admin_user_actor = actor_fixture(account: account, type: :account_admin_user)
      created_tokens = for _ <- 1..3, do: client_token_fixture(account: account, actor: admin_user_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{admin_user_actor.id}/client_tokens")

      assert %{
               "data" => data,
               "metadata" => %{"count" => 3, "limit" => 50}
             } = json_response(conn, 200)

      response_token_ids = Enum.map(data, & &1["id"])
      created_token_ids = Enum.map(created_tokens, & &1.id)
      assert equal_ids?(response_token_ids, created_token_ids)

      Enum.each(data, fn token ->
        assert is_binary(token["actor_id"])
        assert is_binary(token["expires_at"])
        assert is_binary(token["inserted_at"])
        assert is_binary(token["updated_at"])
        refute Map.has_key?(token, "token")
      end)
    end

    test "returns empty list for non-revocable actor type", %{conn: conn, account: account, actor: actor} do
      api_client_actor = actor_fixture(account: account, type: :api_client)
      ignored_token = client_token_fixture(account: account, actor: api_client_actor)
      assert ignored_token.actor_id == api_client_actor.id

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{api_client_actor.id}/client_tokens")

      assert %{"data" => [], "metadata" => %{"count" => 0, "limit" => 50}} = json_response(conn, 200)
    end

    test "does not list tokens from another account", %{conn: conn, actor: actor} do
      other_account = account_fixture()
      other_service_account = service_account_fixture(account: other_account)
      _other_token = client_token_fixture(account: other_account, actor: other_service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{other_service_account.id}/client_tokens")

      assert %{"data" => [], "metadata" => %{"count" => 0, "limit" => 50}} = json_response(conn, 200)
    end

    test "returns unauthorized when subject cannot read client tokens", %{conn: conn, account: account} do
      unprivileged_actor = actor_fixture(account: account, type: :account_user)
      service_account = service_account_fixture(account: account)

      conn =
        conn
        |> authorize_conn(unprivileged_actor)
        |> get("/actors/#{service_account.id}/client_tokens")

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)
      conn = get(conn, "/actors/#{service_account.id}/client_tokens/#{token.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns client token metadata", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{service_account.id}/client_tokens/#{token.id}")

      response = json_response(conn, 200)

      assert %{
               "data" => %{
                 "id" => id,
                 "actor_id" => actor_id,
                 "expires_at" => expires_at,
                 "inserted_at" => inserted_at,
                 "updated_at" => updated_at
               }
             } = response

      assert id == token.id
      assert actor_id == service_account.id
      assert is_binary(expires_at)
      assert is_binary(inserted_at)
      assert is_binary(updated_at)
      refute Map.has_key?(response["data"], "token")
    end

    test "does not return token for non-revocable actor type", %{conn: conn, account: account, actor: actor} do
      api_client_actor = actor_fixture(account: account, type: :api_client)
      token = client_token_fixture(account: account, actor: api_client_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{api_client_actor.id}/client_tokens/#{token.id}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
    end

    test "does not return token from another account", %{conn: conn, actor: actor} do
      other_account = account_fixture()
      other_service_account = service_account_fixture(account: other_account)
      other_token = client_token_fixture(account: other_account, actor: other_service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{other_service_account.id}/client_tokens/#{other_token.id}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
    end

    test "returns not found for non-existent token", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/actors/#{service_account.id}/client_tokens/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
    end

    test "returns unauthorized when subject cannot read client tokens", %{conn: conn, account: account} do
      unprivileged_actor = actor_fixture(account: account, type: :account_user)
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      conn =
        conn
        |> authorize_conn(unprivileged_actor)
        |> get("/actors/#{service_account.id}/client_tokens/#{token.id}")

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      service_account = service_account_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      conn = post(conn, "/actors/#{service_account.id}/client_tokens", client_token: %{expires_at: expires_at})

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "creates client token for service account and returns secret once", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors/#{service_account.id}/client_tokens", client_token: %{expires_at: expires_at})

      assert %{"data" => %{"id" => id, "token" => encoded_token} = data} = json_response(conn, 201)
      assert is_binary(encoded_token)
      assert data["actor_id"] == service_account.id

      assert Repo.get_by(ClientToken, id: id, actor_id: service_account.id)

      context = Portal.Authentication.Context.build({127, 0, 0, 1}, "testing", [], :client)
      assert {:ok, subject} = Portal.Authentication.authenticate(encoded_token, context)
      assert subject.actor.id == service_account.id
      assert subject.credential.id == id

      list_conn =
        build_conn()
        |> authorize_conn(actor)
        |> get("/actors/#{service_account.id}/client_tokens")

      assert %{"data" => [listed_token | _]} = json_response(list_conn, 200)
      refute Map.has_key?(listed_token, "token")
    end

    test "returns validation error when expires_at is missing", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors/#{service_account.id}/client_tokens", client_token: %{})

      assert %{
               "error" => %{
                 "reason" => "Unprocessable Content",
                 "validation_errors" => %{"expires_at" => ["can't be blank"]}
               }
              } = json_response(conn, 422)
    end

    test "returns validation error when client_token wrapper is missing", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors/#{service_account.id}/client_tokens", %{expires_at: expires_at})

      assert json_response(conn, 400) == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns validation error when expires_at is in the past", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors/#{service_account.id}/client_tokens", client_token: %{expires_at: expires_at})

      assert %{
               "error" => %{
                 "reason" => "Unprocessable Content",
                 "validation_errors" => %{"expires_at" => _}
               }
             } = json_response(conn, 422)
    end

    test "returns bad request for non-service-account actor", %{conn: conn, account: account, actor: actor} do
      user_actor = actor_fixture(account: account, type: :account_user)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      conn =
        conn
        |> authorize_conn(actor)
        |> post("/actors/#{user_actor.id}/client_tokens", client_token: %{expires_at: expires_at})

      assert json_response(conn, 400) ==
               %{"error" => %{"reason" => "Actor must be a service account"}}
    end

    test "does not create client token for actor in another account", %{conn: conn, actor: actor} do
      other_account = account_fixture()
      other_service_account = service_account_fixture(account: other_account)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors/#{other_service_account.id}/client_tokens", client_token: %{expires_at: expires_at})

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
      assert Repo.aggregate(from(t in ClientToken, where: t.actor_id == ^other_service_account.id), :count) == 0
    end

    test "returns unauthorized when subject cannot read the actor", %{conn: conn, account: account} do
      unprivileged_actor = actor_fixture(account: account, type: :account_user)
      service_account = service_account_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      conn =
        conn
        |> authorize_conn(unprivileged_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors/#{service_account.id}/client_tokens", client_token: %{expires_at: expires_at})

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      conn = delete(conn, "/actors/#{service_account.id}/client_tokens/#{token.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes client token", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{service_account.id}/client_tokens/#{token.id}")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == token.id
      refute Repo.get_by(ClientToken, id: token.id)
    end

    test "deletes client token for account_user actor", %{conn: conn, account: account, actor: actor} do
      user_actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: user_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{user_actor.id}/client_tokens/#{token.id}")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == token.id
      refute Repo.get_by(ClientToken, id: token.id)
    end

    test "returns not found when client token does not exist for actor", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      user_actor = actor_fixture(account: account, type: :account_user)
      token = client_token_fixture(account: account, actor: user_actor)
      another_user_actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{another_user_actor.id}/client_tokens/#{token.id}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
      assert Repo.get_by(ClientToken, id: token.id)
    end

    test "returns not found when deleting token for non-revocable actor type", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      api_client_actor = actor_fixture(account: account, type: :api_client)
      token = client_token_fixture(account: account, actor: api_client_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{api_client_actor.id}/client_tokens/#{token.id}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}

      assert Repo.get_by(ClientToken, id: token.id)
    end

    test "does not delete client token from another account", %{conn: conn, actor: actor} do
      other_account = account_fixture()
      other_service_account = service_account_fixture(account: other_account)
      other_token = client_token_fixture(account: other_account, actor: other_service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{other_service_account.id}/client_tokens/#{other_token.id}")

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
      assert Repo.get_by(ClientToken, id: other_token.id)
    end

    test "returns unauthorized when subject cannot delete client tokens", %{conn: conn, account: account} do
      unprivileged_actor = actor_fixture(account: account, type: :account_user)
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      conn =
        conn
        |> authorize_conn(unprivileged_actor)
        |> delete("/actors/#{service_account.id}/client_tokens/#{token.id}")

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
      assert Repo.get_by(ClientToken, id: token.id)
    end
  end

  describe "delete_all/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      service_account = service_account_fixture(account: account)

      conn = delete(conn, "/actors/#{service_account.id}/client_tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns unauthorized when subject cannot delete client tokens", %{
      conn: conn,
      account: account
    } do
      unprivileged_actor = actor_fixture(account: account, type: :account_user)
      service_account = service_account_fixture(account: account)

      conn =
        conn
        |> authorize_conn(unprivileged_actor)
        |> delete("/actors/#{service_account.id}/client_tokens")

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes all client tokens for service account", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      tokens = for _ <- 1..3, do: client_token_fixture(account: account, actor: service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{service_account.id}/client_tokens")

      assert %{"data" => %{"deleted_count" => 3}} = json_response(conn, 200)

      Enum.each(tokens, fn token ->
        refute Repo.get_by(ClientToken, id: token.id)
      end)
    end

    test "deletes all client tokens for account_admin_user actor", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      admin_user_actor = actor_fixture(account: account, type: :account_admin_user)
      tokens = for _ <- 1..3, do: client_token_fixture(account: account, actor: admin_user_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{admin_user_actor.id}/client_tokens")

      assert %{"data" => %{"deleted_count" => 3}} = json_response(conn, 200)

      Enum.each(tokens, fn token ->
        refute Repo.get_by(ClientToken, id: token.id)
      end)
    end

    test "returns deleted_count 0 when deleting all for non-revocable actor type", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      api_client_actor = actor_fixture(account: account, type: :api_client)
      token = client_token_fixture(account: account, actor: api_client_actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{api_client_actor.id}/client_tokens")

      assert json_response(conn, 200) == %{"data" => %{"deleted_count" => 0}}

      assert Repo.get_by(ClientToken, id: token.id)
    end

    test "does not delete client tokens from another account", %{conn: conn, actor: actor} do
      other_account = account_fixture()
      other_service_account = service_account_fixture(account: other_account)
      other_tokens = for _ <- 1..3, do: client_token_fixture(account: other_account, actor: other_service_account)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/actors/#{other_service_account.id}/client_tokens")

      assert json_response(conn, 200) == %{"data" => %{"deleted_count" => 0}}

      Enum.each(other_tokens, fn token ->
        assert Repo.get_by(ClientToken, id: token.id)
      end)
    end
  end
end
