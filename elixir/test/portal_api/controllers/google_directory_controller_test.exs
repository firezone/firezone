defmodule PortalAPI.GoogleDirectoryControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GoogleDirectoryFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/google_directories")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists all google directories", %{conn: conn, account: account, actor: actor} do
      directory = google_directory_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_directories")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, fn d -> d["id"] == directory.id end)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      directory = google_directory_fixture(account: account)
      conn = get(conn, "/google_directories/#{directory.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "shows a google directory with sync fields", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory = google_directory_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_directories/#{directory.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == directory.id
      assert data["group_sync_mode"] == "all"
      assert data["orgunit_sync_enabled"] == true
    end

    test "returns not found for unknown id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_directories/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns unauthorized for an account_user actor", %{conn: conn, account: account} do
      directory = google_directory_fixture(account: account)
      actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/google_directories/#{directory.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end
  end
end
