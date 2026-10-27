defmodule PortalAPI.GoogleAuthProviderControllerTest do
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
      conn = get(conn, "/google_auth_providers")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists all google auth providers", %{conn: conn, account: account, actor: actor} do
      provider = google_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, fn item -> item["id"] == provider.id end)
    end

    test "lists multiple Workspace providers and one personal provider", %{conn: conn, account: account, actor: actor} do
      personal = google_provider_fixture(account: account)
      first = google_provider_fixture(account: account, workspace_domains: ["first.example"])
      second = google_provider_fixture(account: account, workspace_domains: ["second.example"])
      conn = conn |> authorize_conn(actor) |> get("/google_auth_providers")
      data = json_response(conn, 200)["data"]
      by_id = Map.new(data, &{&1["id"], &1})
      assert map_size(by_id) == 3
      assert by_id[personal.id]["workspace_domains"] == []
      assert by_id[first.id]["workspace_domains"] == ["first.example"]
      assert by_id[second.id]["workspace_domains"] == ["second.example"]
      refute Enum.any?(data, &Map.has_key?(&1, "is_legacy_unrestricted"))
    end

    test "only lists providers from the authorized account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_provider = google_provider_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)
      refute Enum.any?(data, fn item -> item["id"] == other_provider.id end)
      assert other_provider.account_id != account.id
    end

    test "returns paginated metadata", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      google_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers")

      assert %{
               "data" => data,
               "metadata" => %{"count" => count, "limit" => limit, "next_page" => next_page}
             } = json_response(conn, 200)

      assert limit == 50
      assert count == 1
      assert length(data) == 1
      assert is_nil(next_page)
    end

    test "returns error for invalid page cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} =
               json_response(conn, 400)
    end

    test "filters by name", %{conn: conn, account: account, actor: actor} do
      match = google_provider_fixture(account: account, name: "Corp SSO")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers", name: "Corp SSO")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == match.id
      assert data["name"] == "Corp SSO"
    end

    test "returns an empty list when the name matches nothing", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _provider = google_provider_fixture(account: account, name: "Corp SSO")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers", name: "Nonexistent")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "does not match a provider in another account by name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _local = google_provider_fixture(account: account, name: "Shared Name")
      other = google_provider_fixture(name: "Shared Name")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers", name: "Shared Name")

      assert %{"data" => [data]} = json_response(conn, 200)
      refute data["id"] == other.id
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      provider = google_provider_fixture(account: account)
      conn = get(conn, "/google_auth_providers/#{provider.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "shows a google auth provider", %{conn: conn, account: account, actor: actor} do
      provider = google_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers/#{provider.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == provider.id
      assert data["account_id"] == account.id
      assert data["issuer"] == provider.issuer
    end

    test "returns a verified domain array", %{conn: conn, actor: actor, account: account} do
      domains = ["primary.example", "secondary.example"]
      provider = google_provider_fixture(account: account, workspace_domains: domains)
      conn = conn |> authorize_conn(actor) |> get("/google_auth_providers/#{provider.id}")
      assert json_response(conn, 200)["data"]["workspace_domains"] == domains
    end

    test "returns an empty array for an unrestricted legacy provider", %{conn: conn, actor: actor, account: account} do
      provider = google_provider_fixture(account: account, workspace_domains: nil, is_legacy_unrestricted: true)
      conn = conn |> authorize_conn(actor) |> get("/google_auth_providers/#{provider.id}")
      assert json_response(conn, 200)["data"]["workspace_domains"] == []
      refute Map.has_key?(json_response(conn, 200)["data"], "is_legacy_unrestricted")
    end

    test "returns not found for unknown id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns unauthorized when actor may not read the provider", %{
      conn: conn,
      account: account
    } do
      provider = google_provider_fixture(account: account)
      unauthorized_actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unauthorized_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_auth_providers/#{provider.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end
  end
end
