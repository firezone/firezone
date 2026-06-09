defmodule PortalAPI.OktaAuthProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/okta_auth_providers")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists all okta auth providers", %{conn: conn, account: account, actor: actor} do
      provider = okta_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, fn item -> item["id"] == provider.id end)
    end

    test "only lists providers from the authorized account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_provider = okta_provider_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)
      refute Enum.any?(data, fn item -> item["id"] == other_provider.id end)
      assert other_provider.account_id != account.id
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      provider = okta_provider_fixture(account: account)
      conn = get(conn, "/okta_auth_providers/#{provider.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "shows an okta auth provider", %{conn: conn, account: account, actor: actor} do
      provider = okta_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_auth_providers/#{provider.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == provider.id
      assert data["account_id"] == account.id
      assert data["okta_domain"] == provider.okta_domain
    end

    test "returns not found for unknown id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_auth_providers/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns unauthorized for an actor without permission", %{conn: conn, account: account} do
      provider = okta_provider_fixture(account: account)
      unprivileged = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_auth_providers/#{provider.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end
  end
end
