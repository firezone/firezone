defmodule PortalAPI.OIDCAuthProviderControllerTest do
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
    test "lists OIDC providers with email_verification_method", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = oidc_provider_fixture(account: account, email_verification_method: :none)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/oidc_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)

      assert Enum.any?(data, fn item ->
               item["id"] == provider.id and item["email_verification_method"] == "none"
             end)
    end
  end

  describe "show/2" do
    test "shows email_verification_method", %{conn: conn, account: account, actor: actor} do
      provider = oidc_provider_fixture(account: account, email_verification_method: :proof)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/oidc_auth_providers/#{provider.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == provider.id
      assert data["email_verification_method"] == "proof"
    end

    test "returns not found for unknown id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/oidc_auth_providers/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns unauthorized when actor may not read the provider", %{
      conn: conn,
      account: account
    } do
      provider = oidc_provider_fixture(account: account)
      unauthorized_actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unauthorized_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/oidc_auth_providers/#{provider.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end
  end
end
