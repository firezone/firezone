defmodule PortalAPI.EmailOTPAuthProviderControllerTest do
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
      conn = get(conn, "/email_otp_auth_providers")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all email OTP auth providers", %{conn: conn, account: account, actor: actor} do
      provider = email_otp_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/email_otp_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, fn item -> item["id"] == provider.id end)
    end

    test "only lists providers from the authorized account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_provider = email_otp_provider_fixture()

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/email_otp_auth_providers")

      assert %{"data" => data} = json_response(conn, 200)
      refute Enum.any?(data, fn item -> item["id"] == other_provider.id end)
      assert other_provider.account_id != account.id
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      provider = email_otp_provider_fixture(account: account)
      conn = get(conn, "/email_otp_auth_providers/#{provider.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "shows an email OTP auth provider", %{conn: conn, account: account, actor: actor} do
      provider = email_otp_provider_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/email_otp_auth_providers/#{provider.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == provider.id
      assert data["account_id"] == account.id
    end

    test "returns not found for unknown id", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/email_otp_auth_providers/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns unauthorized when actor may not read the provider", %{
      conn: conn,
      account: account
    } do
      provider = email_otp_provider_fixture(account: account)
      unauthorized_actor = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unauthorized_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/email_otp_auth_providers/#{provider.id}")

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end
  end
end
