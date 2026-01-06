defmodule PortalAPI.GatewayTokenControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.GatewayToken

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = post(conn, "/sites/#{site.id}/gateway_tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "creates a gateway token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateway_tokens")

      assert %{"data" => %{"id" => _id, "token" => _token}} = json_response(conn, 201)
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: site)
      conn = delete(conn, "/sites/#{site.id}/gateway_tokens/#{token.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes gateway token", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/sites/#{site.id}/gateway_tokens/#{token.id}")

      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)

      refute Repo.get_by(GatewayToken, id: token.id, account_id: token.account_id)
    end
  end

  describe "delete_all/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = delete(conn, "/sites/#{site.id}/gateway_tokens")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes all gateway tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(account: account)

      tokens = for _ <- 1..3, do: gateway_token_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{site.id}/gateway_tokens")

      assert %{"data" => %{"deleted_count" => 3}} = json_response(conn, 200)

      Enum.each(tokens, fn token ->
        refute Repo.get_by(GatewayToken, id: token.id, account_id: token.account_id)
      end)
    end
  end
end
