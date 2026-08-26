defmodule PortalAPI.X509AuthProviderControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.FeaturesFixtures

  setup do
    enable_feature(:trust_anchors)
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/x509_auth_provider")

      assert %{"status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "shows the account's singleton X.509 provider", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = x509_provider_fixture(account: account)
      _other_provider = x509_provider_fixture()

      conn = conn |> authorize_conn(actor) |> get("/x509_auth_provider")

      assert %{
               "data" => %{
                 "id" => provider_id,
                 "account_id" => account_id,
                 "name" => "X.509",
                 "context" => "clients_only",
                 "is_disabled" => true
               }
             } = json_response(conn, 200)

      assert provider_id == provider.id
      assert account_id == account.id
    end

    test "returns not found when the account has no X.509 provider", %{
      conn: conn,
      actor: actor
    } do
      conn = conn |> authorize_conn(actor) |> get("/x509_auth_provider")

      assert json_response(conn, 404)
    end

    test "is unavailable when trust anchors are globally disabled", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _provider = x509_provider_fixture(account: account)
      disable_feature(:trust_anchors)

      conn = conn |> authorize_conn(actor) |> get("/x509_auth_provider")

      assert json_response(conn, 404)
    end
  end
end
