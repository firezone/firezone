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
    test "lists OIDC providers with require_email_verified", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = oidc_provider_fixture(account: account, require_email_verified: false)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/oidc_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)

      assert Enum.any?(data, fn item ->
               item["id"] == provider.id and item["require_email_verified"] == false
             end)
    end
  end

  describe "show/2" do
    test "shows require_email_verified", %{conn: conn, account: account, actor: actor} do
      provider = oidc_provider_fixture(account: account, require_email_verified: true)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/oidc_auth_providers/#{provider.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == provider.id
      assert data["require_email_verified"] == true
    end
  end
end
