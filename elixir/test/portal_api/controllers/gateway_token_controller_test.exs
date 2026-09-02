defmodule PortalAPI.GatewayTokenControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.GatewayToken

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
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

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = get(conn, "/sites/#{site.id}/gateway_tokens")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists a site's own tokens and its gateways' tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)
      site_token = gateway_token_fixture(account: account, site: site)
      gateway_token = gateway_token_fixture(gateway: gateway)

      other_site = site_fixture(%{account: account})
      other_token = gateway_token_fixture(account: account, site: other_site)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/sites/#{site.id}/gateway_tokens")

      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])

      assert site_token.id in ids
      assert gateway_token.id in ids
      refute other_token.id in ids
    end

    test "renders metadata and never a token value", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(gateway: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/sites/#{site.id}/gateway_tokens")

      assert %{"data" => data} = json_response(conn, 200)
      assert entry = Enum.find(data, &(&1["id"] == token.id))

      assert entry["gateway_id"] == gateway.id
      assert entry["site_id"] == nil
      assert entry["rotated_at"] == nil
      assert entry["inserted_at"]
      refute Map.has_key?(entry, "token")
    end

    test "returns not found when site does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get("/sites/#{Ecto.UUID.generate()}/gateway_tokens")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: site)
      conn = get(conn, "/sites/#{site.id}/gateway_tokens/#{token.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "renders metadata and never a token value", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/sites/#{site.id}/gateway_tokens/#{token.id}")

      assert %{"data" => data} = json_response(conn, 200)

      assert data["id"] == token.id
      assert data["site_id"] == site.id
      assert data["gateway_id"] == nil
      assert data["inserted_at"]
      refute Map.has_key?(data, "token")
    end

    test "returns not found for a token belonging to another site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      other_site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: other_site)

      conn =
        conn
        |> authorize_conn(actor)
        |> get("/sites/#{site.id}/gateway_tokens/#{token.id}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = post(conn, "/sites/#{site.id}/gateway_tokens")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

    test "sets Deprecation and Sunset headers", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateway_tokens")

      assert get_resp_header(conn, "deprecation") == ["true"]
      assert [sunset] = get_resp_header(conn, "sunset")
      assert sunset =~ ~r/^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/
    end

    test "returns not found when site does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{Ecto.UUID.generate()}/gateway_tokens")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "create_for_gateway/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)

      conn = post(conn, "/sites/#{site.id}/gateways/#{gateway.id}/token")

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "creates a single-owner gateway token", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateways/#{gateway.id}/token")

      assert %{"data" => %{"id" => id, "token" => _token}} = json_response(conn, 201)

      token = Repo.get_by!(GatewayToken, account_id: account.id, id: id)
      assert token.device_id == gateway.id
      assert is_nil(token.site_id)
    end

    test "returns conflict when an active token already exists", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)
      gateway_token_fixture(gateway: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateways/#{gateway.id}/token")

      assert %{"status" => 409, "title" => "Conflict"} = json_response(conn, 409)
    end

    test "returns not found when gateway does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{Ecto.UUID.generate()}/gateways/#{Ecto.UUID.generate()}/token")

      assert %{"status" => 404} = json_response(conn, 404)
    end

    test "returns not found when the gateway belongs to another site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      other_site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{other_site.id}/gateways/#{gateway.id}/token")

      assert %{"status" => 404} = json_response(conn, 404)
    end

    test "returns not found for a gateway in another account", %{conn: conn, actor: actor} do
      other_gateway = gateway_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{other_gateway.site_id}/gateways/#{other_gateway.id}/token")

      assert %{"status" => 404} = json_response(conn, 404)
    end
  end

  describe "rotate/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)

      conn = post(conn, "/sites/#{site.id}/gateways/#{gateway.id}/token/rotate")

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "rotates an in-use gateway token", %{conn: conn, account: account, actor: actor} do
      site = site_fixture(%{account: account})
      # The fixture session references the single-owner token, marking it in use
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)
      old_token = Repo.get_by!(GatewayToken, account_id: account.id, device_id: gateway.id)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateways/#{gateway.id}/token/rotate")

      assert %{"data" => %{"id" => new_id, "token" => _token}} = json_response(conn, 201)
      assert new_id != old_token.id

      old_token = Repo.get_by!(GatewayToken, account_id: account.id, id: old_token.id)
      assert old_token.rotated_at != nil

      new_token = Repo.get_by!(GatewayToken, account_id: account.id, id: new_id)
      assert is_nil(new_token.rotated_at)
    end

    test "rotating a never-used token replaces it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)
      old_token = gateway_token_fixture(gateway: gateway)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateways/#{gateway.id}/token/rotate")

      assert %{"data" => %{"id" => new_id, "token" => _token}} = json_response(conn, 201)
      assert new_id != old_token.id

      refute Repo.get_by(GatewayToken, account_id: account.id, id: old_token.id)
    end

    test "rotating with no existing token mints one", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{site.id}/gateways/#{gateway.id}/token/rotate")

      assert %{"data" => %{"id" => _id, "token" => _token}} = json_response(conn, 201)
    end

    test "returns not found when gateway does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{Ecto.UUID.generate()}/gateways/#{Ecto.UUID.generate()}/token/rotate")

      assert %{"status" => 404} = json_response(conn, 404)
    end

    test "returns not found when the gateway belongs to another site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      other_site = site_fixture(%{account: account})
      gateway = gateway_fixture(account: account, site: site, token: :single_owner)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/sites/#{other_site.id}/gateways/#{gateway.id}/token/rotate")

      assert %{"status" => 404} = json_response(conn, 404)
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: site)
      conn = delete(conn, "/sites/#{site.id}/gateway_tokens/#{token.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

    test "returns not found when token does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/sites/#{site.id}/gateway_tokens/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "returns unauthorized when actor cannot read the token", %{
      conn: conn,
      account: account
    } do
      account_user = actor_fixture(type: :account_user, account: account)
      site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: site)

      conn =
        conn
        |> authorize_conn(account_user)
        |> delete("/sites/#{site.id}/gateway_tokens/#{token.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns not found when the token belongs to a different site", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      site = site_fixture(%{account: account})
      other_site = site_fixture(%{account: account})
      token = gateway_token_fixture(account: account, site: other_site)

      conn =
        conn
        |> authorize_conn(actor)
        |> delete("/sites/#{site.id}/gateway_tokens/#{token.id}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)

      assert Repo.get_by(GatewayToken, id: token.id, account_id: token.account_id)
    end
  end

  describe "delete_all/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      site = site_fixture(%{account: account})
      conn = delete(conn, "/sites/#{site.id}/gateway_tokens")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

    test "returns not found when site does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/sites/#{Ecto.UUID.generate()}/gateway_tokens")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end
end
