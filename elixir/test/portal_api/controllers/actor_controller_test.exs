defmodule API.ActorControllerTest do
  use API.ConnCase, async: true
  alias Domain.Actor

  import Domain.AccountFixtures
  import Domain.ActorFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :api_client, account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/actors")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all actors", %{conn: conn, account: account, actor: actor} do
      actors = for _ <- 1..3, do: actor_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert count == 4
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"])
      actor_ids = Enum.map(actors, & &1.id) ++ [actor.id]

      assert equal_ids?(data_ids, actor_ids)
    end

    test "lists actors with limit", %{conn: conn, account: account, actor: actor} do
      actors = for _ <- 1..3, do: actor_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors", limit: "2")

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
      assert count == 4
      refute is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      actor_ids = (Enum.map(actors, & &1.id) ++ [actor.id]) |> MapSet.new()

      assert MapSet.subset?(data_ids, actor_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor = actor_fixture(account: account)
      conn = get(conn, "/actors/#{actor.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single actor", %{conn: conn, account: account, actor: api_actor} do
      actor = actor_with_email_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{actor.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => actor.id,
                 "name" => actor.name,
                 "type" => Atom.to_string(actor.type),
                 "allow_email_otp_sign_in" => actor.allow_email_otp_sign_in,
                 "created_by_directory_id" => actor.created_by_directory_id,
                 "disabled_at" => iso8601(actor.disabled_at),
                 "email" => actor.email,
                 "inserted_at" => iso8601(actor.inserted_at),
                 "last_seen_at" => iso8601(actor.last_seen_at),
                 "updated_at" => iso8601(actor.updated_at)
               }
             }
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/actors", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: api_actor} do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid attrs", %{conn: conn, actor: api_actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "error" => %{
                   "reason" => "Unprocessable Content",
                   "validation_errors" => %{
                     "name" => ["can't be blank"],
                     "type" => ["can't be blank"]
                   }
                 }
               }
    end

    test "returns error when users limit hit", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      Ecto.Changeset.change(account, limits: %Domain.Accounts.Limits{users_count: 1})
      |> Repo.update!()

      actor_with_email_fixture(type: :account_user, account: account)

      attrs = %{
        "name" => "Test User",
        "email" => "new_actor@example.com",
        "type" => "account_user"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert resp = json_response(conn, 422)
      assert resp == %{"error" => %{"reason" => "Users Limit Reached"}}
    end

    test "returns error when service accounts limit hit", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      Ecto.Changeset.change(account, limits: %Domain.Accounts.Limits{service_accounts_count: 1})
      |> Repo.update!()

      service_account_fixture(type: :service_account, account: account)

      attrs = %{
        "name" => "Test Service Account",
        "type" => "service_account"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert resp = json_response(conn, 422)
      assert resp == %{"error" => %{"reason" => "Service Accounts Limit Reached"}}
    end

    test "creates a actor with valid attrs", %{conn: conn, actor: api_actor} do
      # TODO: At the moment, API clients aren't allowed to create admin users
      attrs = %{
        "name" => "Test User",
        "email" => "test_user@example.com",
        "type" => "account_user"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["name"] == attrs["name"]
      assert resp["data"]["email"] == attrs["email"]
      assert resp["data"]["type"] == attrs["type"]
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor = actor_fixture(account: account)
      conn = put(conn, "/actors/#{actor.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      actor = actor_fixture(account: account, type: :account_admin_user)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "updates an actor", %{conn: conn, account: account, actor: api_actor} do
      actor = actor_fixture(account: account, type: :account_admin_user)
      _other_admin = actor_fixture(account: account, type: :account_admin_user)

      attrs = %{"type" => "account_user"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["id"] == actor.id
      assert resp["data"]["name"] == actor.name
      assert resp["data"]["type"] == attrs["type"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor = actor_fixture(account: account)
      conn = delete(conn, "/actors/#{actor.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a resource", %{conn: conn, account: account, actor: api_actor} do
      actor = actor_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/actors/#{actor.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => actor.id,
                 "name" => actor.name,
                 "type" => Atom.to_string(actor.type),
                 "allow_email_otp_sign_in" => actor.allow_email_otp_sign_in,
                 "created_by_directory_id" => actor.created_by_directory_id,
                 "disabled_at" => iso8601(actor.disabled_at),
                 "email" => actor.email,
                 "inserted_at" => iso8601(actor.inserted_at),
                 "last_seen_at" => iso8601(actor.last_seen_at),
                 "updated_at" => iso8601(actor.updated_at)
               }
             }

      refute Repo.get_by(Actor, id: actor.id, account_id: actor.account_id)
    end
  end

  defp iso8601(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp iso8601(_), do: nil
end
