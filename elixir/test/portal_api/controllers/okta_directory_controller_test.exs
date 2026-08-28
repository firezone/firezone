defmodule PortalAPI.OktaDirectoryControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OktaDirectoryFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/okta_directories")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists all okta directories", %{conn: conn, account: account, actor: actor} do
      directory = okta_directory_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, fn d -> d["id"] == directory.id end)
    end

    test "filters by name", %{conn: conn, account: account, actor: actor} do
      match = okta_directory_fixture(account: account, name: "Corp Directory")
      _other = okta_directory_fixture(account: account, name: "Other Directory")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories", name: "Corp Directory")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == match.id
      assert data["name"] == "Corp Directory"
    end

    test "returns an empty list when the name matches nothing", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _directory = okta_directory_fixture(account: account, name: "Corp Directory")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories", name: "Nonexistent")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "does not match a directory in another account by name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _local = okta_directory_fixture(account: account, name: "Shared Name")
      other = okta_directory_fixture(name: "Shared Name")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories", name: "Shared Name")

      assert %{"data" => [data]} = json_response(conn, 200)
      refute data["id"] == other.id
    end

    test "only lists directories from the authorized account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_directory = okta_directory_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories")

      assert %{"data" => data} = json_response(conn, 200)
      refute Enum.any?(data, fn d -> d["id"] == other_directory.id end)
      assert other_directory.account_id != account.id
    end

    test "returns paginated metadata and respects limit", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      for _ <- 1..3, do: okta_directory_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories", limit: "2")

      assert %{
               "data" => data,
               "metadata" => %{"count" => count, "limit" => limit, "next_page" => next_page}
             } = json_response(conn, 200)

      assert limit == 2
      assert count == 3
      assert length(data) == 2
      refute is_nil(next_page)
    end

    test "returns error for invalid page cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} =
               json_response(conn, 400)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      directory = okta_directory_fixture(account: account)
      conn = get(conn, "/okta_directories/#{directory.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "shows an okta directory", %{conn: conn, account: account, actor: actor} do
      directory = okta_directory_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories/#{directory.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == directory.id
      assert data["account_id"] == account.id
      assert data["okta_domain"] == directory.okta_domain
    end

    test "response keys match the OpenAPI schema properties", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory = okta_directory_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories/#{directory.id}")

      assert %{"data" => data} = json_response(conn, 200)

      documented =
        PortalAPI.Schemas.OktaDirectory.Schema.schema().properties
        |> Map.keys()
        |> Enum.map(&Atom.to_string/1)
        |> MapSet.new()

      assert MapSet.new(Map.keys(data)) == documented
    end

    test "returns not found for unknown id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns unauthorized for an account_user actor", %{conn: conn, account: account} do
      directory = okta_directory_fixture(account: account)
      actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/okta_directories/#{directory.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end
  end
end
