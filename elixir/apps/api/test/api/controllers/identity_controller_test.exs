defmodule API.IdentityControllerTest do
  use API.ConnCase, async: true
  alias Domain.Auth.Identity

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index" do
    test "returns error when not authorized", %{conn: conn, actor: actor} do
      conn = post(conn, "/v1/actors/#{actor.id}/identities")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "lists all identities for actor", %{conn: conn, account: account, actor: actor} do
      identities =
        for _ <- 1..3, do: Fixtures.Auth.create_identity(%{account: account, actor: actor})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/actors/#{actor.id}/identities")

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
      identity_ids = Enum.map(identities, & &1.id) |> MapSet.new()

      assert MapSet.equal?(data_ids, identity_ids)
    end

    test "lists resources with limit", %{conn: conn, account: account, actor: actor} do
      identities =
        for _ <- 1..3, do: Fixtures.Auth.create_identity(%{account: account, actor: actor})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/actors/#{actor.id}/identities", limit: "2")

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

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      identity_ids = Enum.map(identities, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, identity_ids)
    end
  end

  describe "show" do
    test "returns error when not authorized", %{conn: conn, account: account, actor: actor} do
      identity = Fixtures.Auth.create_identity(%{account: account, actor: actor})
      conn = get(conn, "/v1/actors/#{actor.id}/identities/#{identity.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns a single resource", %{conn: conn, account: account, actor: actor} do
      identity = Fixtures.Auth.create_identity(%{account: account, actor: actor})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/actors/#{actor.id}/identities/#{identity.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => identity.id,
                 "actor_id" => actor.id,
                 "provider_id" => identity.provider_id,
                 "provider_identifier" => identity.provider_identifier
               }
             }
    end
  end

  describe "create" do
    test "returns error when not authorized", %{conn: conn, actor: actor} do
      conn = post(conn, "/v1/actors/#{actor.id}/identities", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns errors on invalid attrs", %{conn: conn, actor: actor} do
      assert false
      #  attrs = %{}

      #  conn =
      #    conn
      #    |> authorize_conn(actor)
      #    |> put_req_header("content-type", "application/json")
      #    |> post("/v1/actors/#{actor.id}/identities", identity: attrs)

      #  assert resp = json_response(conn, 422)

      #  assert resp ==
      #           %{
      #             "errors" => %{
      #               "address" => ["can't be blank"],
      #               "connections" => ["can't be blank"],
      #               "name" => ["can't be blank"],
      #               "type" => ["can't be blank"]
      #             }
      #           }
    end

    test "creates a resource with valid attrs", %{conn: conn, account: account, actor: actor} do
      assert false
      #  gateway_group = Fixtures.Gateways.create_group(%{account: account})

      #  attrs = %{
      #    "address" => "google.com",
      #    "name" => "Google",
      #    "type" => "dns",
      #    "connections" => [
      #      %{"gateway_group_id" => gateway_group.id}
      #    ]
      #  }

      #  conn =
      #    conn
      #    |> authorize_conn(actor)
      #    |> put_req_header("content-type", "application/json")
      #    |> post("/v1/resources", resource: attrs)

      #  assert resp = json_response(conn, 201)

      #  assert resp["data"]["address"] == attrs["address"]
      #  assert resp["data"]["description"] == nil
      #  assert resp["data"]["name"] == attrs["name"]
      #  assert resp["data"]["type"] == attrs["type"]
    end
  end

  describe "delete" do
    test "returns error when not authorized", %{conn: conn, account: account, actor: actor} do
      identity = Fixtures.Auth.create_identity(%{account: account, actor: actor})
      conn = delete(conn, "/v1/actors/#{actor.id}/identities/#{identity.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "deletes a resource", %{conn: conn, account: account, actor: actor} do
      identity = Fixtures.Auth.create_identity(%{account: account, actor: actor})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/v1/actors/#{actor.id}/identities/#{identity.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => identity.id,
                 "actor_id" => actor.id,
                 "provider_id" => identity.provider_id,
                 "provider_identifier" => identity.provider_identifier
               }
             }

      assert {:error, :not_found} ==
               Identity.Query.not_deleted()
               |> Identity.Query.by_id(identity.id)
               |> Repo.fetch(Identity.Query)
    end
  end
end
