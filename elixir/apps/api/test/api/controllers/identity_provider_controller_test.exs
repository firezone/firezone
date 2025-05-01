defmodule API.IdentityProviderControllerTest do
  use API.ConnCase, async: true
  alias Domain.Auth.Provider

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/identity_providers")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all identity_providers", %{conn: conn, account: account, actor: actor} do
      {oidc_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      {google_provider, _bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/identity_providers")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert count == 3
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()

      provider_ids =
        Enum.map([oidc_provider, google_provider], & &1.id) |> MapSet.new()

      assert MapSet.subset?(provider_ids, data_ids)
    end

    test "lists identity providers with limit", %{conn: conn, account: account, actor: actor} do
      Fixtures.Auth.start_and_create_openid_connect_provider(%{account: account})
      Fixtures.Auth.start_and_create_google_workspace_provider(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/identity_providers", limit: "2")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert limit == 2
      assert count == 3
      refute is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"])

      assert length(data_ids) == 2
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      {identity_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(%{account: account})

      conn = get(conn, "/identity_providers/#{identity_provider.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single resource", %{conn: conn, account: account, actor: actor} do
      {identity_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/identity_providers/#{identity_provider.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => identity_provider.id,
                 "name" => identity_provider.name
               }
             }
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      {identity_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(%{account: account})

      conn = delete(conn, "/identity_providers/#{identity_provider.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes an identity provider", %{conn: conn, account: account, actor: actor} do
      {identity_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/identity_providers/#{identity_provider.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => identity_provider.id,
                 "name" => identity_provider.name
               }
             }

      refute Repo.get(Provider, identity_provider.id)
    end
  end
end
