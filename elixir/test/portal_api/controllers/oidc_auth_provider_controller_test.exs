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
  end
end
