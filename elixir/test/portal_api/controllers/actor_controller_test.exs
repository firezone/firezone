defmodule PortalAPI.ActorControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Actor
  alias Portal.ExternalIdentity

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.IdentityFixtures

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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns unauthorized for an actor without permission", %{conn: conn, account: account} do
      unprivileged = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> get("/actors")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

    test "returns error for a non-integer limit", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors", limit: "abc")

      assert %{"type" => "about:blank", "status" => 400} = json_response(conn, 400)
    end

    test "returns error for a limit outside 1 to 100", %{conn: conn, actor: actor} do
      for limit <- ["0", "-1", "101"] do
        conn =
          conn
          |> authorize_conn(actor)
          |> put_req_header("content-type", "application/json")
          |> get("/actors", limit: limit)

        assert %{"type" => "about:blank", "status" => 400} = json_response(conn, 400)
      end
    end

    test "filters by exact name match", %{conn: conn, account: account, actor: actor} do
      target = actor_fixture(account: account, name: "alice", type: :account_user)
      _other = actor_fixture(account: account, name: "bob", type: :account_user)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors", name: "alice")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == target.id
    end

    test "filters by exact email match", %{conn: conn, account: account, actor: actor} do
      target = actor_fixture(account: account, email: "alice@example.com", type: :account_user)
      _other = actor_fixture(account: account, email: "bob@example.com", type: :account_user)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors", email: "alice@example.com")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == target.id
    end

    test "filters by type", %{conn: conn, account: account, actor: actor} do
      target = actor_fixture(account: account, type: :service_account)
      _other = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors", type: "service_account")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == target.id
    end

    test "rejects an invalid type filter value", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors", type: "bogus")

      assert %{"status" => 400} = json_response(conn, 400)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor = actor_fixture(account: account)
      conn = get(conn, "/actors/#{actor.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns not found for unknown id", %{conn: conn, actor: api_actor} do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "returns unauthorized for an actor without permission", %{conn: conn, account: account} do
      target = actor_fixture(account: account)
      unprivileged = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{target.id}")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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
                 "is_disabled" => actor.is_disabled,
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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, actor: api_actor} do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
    end

    test "returns error on invalid attrs", %{conn: conn, actor: api_actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert %{
               "status" => 422,
               "validation_errors" => %{
                 "name" => ["can't be blank"],
                 "type" => ["can't be blank"]
               }
             } = json_response(conn, 422)
    end

    test "does not allow creating api_client actors", %{conn: conn, actor: api_actor} do
      attrs = %{
        "name" => "Rogue API Client",
        "type" => "api_client"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert %{
               "status" => 422,
               "validation_errors" => %{
                 "type" => ["is invalid"]
               }
             } = json_response(conn, 422)
    end

    test "returns error when users limit hit", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      Ecto.Changeset.change(account, limits: %Portal.Accounts.Limits{users_count: 1})
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

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Users limit reached"} =
               json_response(conn, 403)
    end

    test "returns error when users limit hit for admin user", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      Ecto.Changeset.change(account, limits: %Portal.Accounts.Limits{users_count: 1})
      |> Repo.update!()

      actor_with_email_fixture(type: :account_user, account: account)

      attrs = %{
        "name" => "Test Admin",
        "email" => "admin@example.com",
        "type" => "account_admin_user"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Users limit reached"} =
               json_response(conn, 403)
    end

    test "returns error when service accounts limit hit", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      Ecto.Changeset.change(account, limits: %Portal.Accounts.Limits{service_accounts_count: 1})
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

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Service accounts limit reached"} =
               json_response(conn, 403)
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

    test "returns validation error when email host has no dot", %{conn: conn, actor: api_actor} do
      attrs = %{
        "name" => "Test User",
        "email" => "test_user@localhost",
        "type" => "account_user"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert %{
               "status" => 422,
               "validation_errors" => %{
                 "email" => ["is an invalid email address"]
               }
             } = json_response(conn, 422)
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor = actor_fixture(account: account)
      conn = put(conn, "/actors/#{actor.id}", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      actor = actor_fixture(account: account, type: :account_admin_user)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
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

    test "returns error when promoting to admin and admin limit reached", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_user)

      # Create an admin to fill the limit
      actor_fixture(account: account, type: :account_admin_user)

      # Set admin limit to 1 (the existing admin already fills it)
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 1}
      )
      |> Repo.update!()

      attrs = %{"type" => "account_admin_user"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Admins limit reached"} =
               json_response(conn, 403)
    end

    test "allows promoting to admin when under the limit", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_user)

      # Set admin limit to 5 (plenty of room)
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 5}
      )
      |> Repo.update!()

      attrs = %{"type" => "account_admin_user"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert json_response(conn, 200)

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id).type ==
               :account_admin_user
    end

    test "allows promoting to admin when limit is nil", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_user)

      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: nil}
      )
      |> Repo.update!()

      attrs = %{"type" => "account_admin_user"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert json_response(conn, 200)

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id).type ==
               :account_admin_user
    end

    test "allows demoting admin to user even when admin limit is reached", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      admin = actor_fixture(account: account, type: :account_admin_user)

      # Create a second admin so the first can be demoted
      actor_fixture(account: account, type: :account_admin_user)

      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 1}
      )
      |> Repo.update!()

      attrs = %{"type" => "account_user"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{admin.id}", actor: attrs)

      assert json_response(conn, 200)

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: admin.id).type ==
               :account_user
    end

    test "returns error when creating admin user and admin limit reached", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      # Create an admin to fill the limit
      actor_fixture(account: account, type: :account_admin_user)

      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 1}
      )
      |> Repo.update!()

      attrs = %{
        "name" => "New Admin",
        "email" => "new-admin@example.com",
        "type" => "account_admin_user"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Admins limit reached"} =
               json_response(conn, 403)
    end

    test "allows creating admin user when under the limit", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 5}
      )
      |> Repo.update!()

      attrs = %{
        "name" => "New Admin",
        "email" => "new-admin@example.com",
        "type" => "account_admin_user"
      }

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> post("/actors", actor: attrs)

      assert json_response(conn, 201)
    end

    test "rejects changing account_user to service_account", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_user)

      attrs = %{"type" => "service_account"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert resp = json_response(conn, 422)
      assert resp["validation_errors"]["type"] ==
               ["cannot change a user to a service account or API client"]

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id).type ==
               :account_user
    end

    test "rejects changing account_user to api_client", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_user)

      attrs = %{"type" => "api_client"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert resp = json_response(conn, 422)
      assert resp["validation_errors"]["type"] ==
               ["is invalid"]

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id).type ==
               :account_user
    end

    test "rejects changing account_admin_user to service_account", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_admin_user)
      _other_admin = actor_fixture(account: account, type: :account_admin_user)

      attrs = %{"type" => "service_account"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert resp = json_response(conn, 422)
      assert resp["validation_errors"]["type"] ==
               ["cannot change a user to a service account or API client"]

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id).type ==
               :account_admin_user
    end

    test "rejects changing account_admin_user to api_client", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = actor_fixture(account: account, type: :account_admin_user)
      _other_admin = actor_fixture(account: account, type: :account_admin_user)

      attrs = %{"type" => "api_client"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: attrs)

      assert resp = json_response(conn, 422)
      assert resp["validation_errors"]["type"] ==
               ["is invalid"]

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id).type ==
               :account_admin_user
    end

    test "rejects changing api_client to any other type", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      target = actor_fixture(account: account, type: :api_client)

      for type <- ["account_user", "account_admin_user", "service_account"] do
        request_conn =
          conn
          |> recycle()
          |> authorize_conn(api_actor)
          |> put_req_header("content-type", "application/json")
          |> put("/actors/#{target.id}", actor: %{"type" => type})

        assert resp = json_response(request_conn, 422)
        assert resp["validation_errors"]["type"] ==
                 ["cannot change the type of an API client"]
      end

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: target.id).type ==
               :api_client
    end

    test "rejects changing service_account to any other type", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      target = actor_fixture(account: account, type: :service_account)

      for type <- ["account_user", "account_admin_user", "api_client"] do
        request_conn =
          conn
          |> recycle()
          |> authorize_conn(api_actor)
          |> put_req_header("content-type", "application/json")
          |> put("/actors/#{target.id}", actor: %{"type" => type})

        assert resp = json_response(request_conn, 422)

        # api_client is not a type the request schema accepts at all.
        expected =
          if type == "api_client",
            do: ["is invalid"],
            else: ["cannot change the type of a service account"]

        assert resp["validation_errors"]["type"] == expected
      end

      assert Repo.get_by!(Portal.Actor, account_id: account.id, id: target.id).type ==
               :service_account
    end

    test "clears external identities when email is changed", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      target = actor_with_email_fixture(account: account)
      identity1 = identity_fixture(account: account, actor: target)
      identity2 = identity_fixture(account: account, actor: target)

      attrs = %{"email" => "rotated-#{target.email}"}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{target.id}", actor: attrs)

      assert resp = json_response(conn, 200)
      assert resp["data"]["email"] == "rotated-#{target.email}"

      refute Repo.get_by(ExternalIdentity, id: identity1.id, account_id: account.id)
      refute Repo.get_by(ExternalIdentity, id: identity2.id, account_id: account.id)
    end

    test "does not clear identities when email is unchanged", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      target = actor_with_email_fixture(account: account)
      identity = identity_fixture(account: account, actor: target)

      attrs = %{"name" => "Renamed", "email" => target.email}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{target.id}", actor: attrs)

      assert json_response(conn, 200)
      assert Repo.get_by(ExternalIdentity, id: identity.id, account_id: account.id)
    end

    test "does not clear identities when email differs only by whitespace", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      target = actor_with_email_fixture(account: account)
      identity = identity_fixture(account: account, actor: target)

      attrs = %{"email" => "  #{target.email}  "}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{target.id}", actor: attrs)

      assert json_response(conn, 200)
      assert Repo.get_by(ExternalIdentity, id: identity.id, account_id: account.id)
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      actor = actor_fixture(account: account)
      conn = delete(conn, "/actors/#{actor.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns not found for unknown id", %{conn: conn, actor: api_actor} do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/actors/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
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
                 "is_disabled" => actor.is_disabled,
                 "email" => actor.email,
                 "inserted_at" => iso8601(actor.inserted_at),
                 "last_seen_at" => iso8601(actor.last_seen_at),
                 "updated_at" => iso8601(actor.updated_at)
               }
             }

      refute Repo.get_by(Actor, id: actor.id, account_id: actor.account_id)
    end
  end

  describe "Database.delete_actor_by_id/2" do
    test "returns unauthorized for a subject that may not delete Actors", %{account: account} do
      # Not reachable through the REST API today - tokens only decode under the
      # api_client salt - but Safe.delete_all/2 can still return this, and it
      # has to surface as a 403 rather than crashing the request.
      subject =
        Portal.SubjectFixtures.subject_fixture(
          account: account,
          actor: [type: :service_account]
        )

      actor = actor_fixture(account: account)

      assert PortalAPI.ActorController.Database.delete_actor_by_id(actor.id, subject) ==
               {:error, :unauthorized}

      assert Repo.get_by(Actor, id: actor.id, account_id: account.id)
    end
  end

  describe "update/2 is_disabled" do
    test "disables an actor", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      # Client token / portal session revocation on disable is driven by an
      # async replication consumer (Portal.Changes.Hooks.Actors.on_update/3)
      # that doesn't fire on a Repo.update inside the test sandbox - see
      # test/portal/changes/hooks/actors_test.exs for that behavior.
      actor = actor_fixture(account: account, type: :service_account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: %{"is_disabled" => true})

      assert %{"data" => %{"id" => id, "is_disabled" => true}} = json_response(conn, 200)
      assert id == actor.id
      assert Repo.get_by!(Actor, account_id: account.id, id: actor.id).is_disabled
    end

    test "disabling an already-disabled actor is idempotent", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      actor = disabled_actor_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: %{"is_disabled" => true})

      assert %{"data" => %{"id" => id, "is_disabled" => true}} = json_response(conn, 200)
      assert id == actor.id
    end

    test "enables a disabled actor", %{conn: conn, account: account, actor: api_actor} do
      actor = disabled_actor_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{actor.id}", actor: %{"is_disabled" => false})

      assert %{"data" => %{"id" => id, "is_disabled" => false}} = json_response(conn, 200)
      assert id == actor.id
      refute Repo.get_by!(Actor, account_id: account.id, id: actor.id).is_disabled
    end

    test "returns forbidden when actor attempts to disable itself", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{api_actor.id}", actor: %{"is_disabled" => true})

      assert %{"type" => "about:blank", "status" => 403} = json_response(conn, 403)
      refute Repo.get_by!(Actor, account_id: account.id, id: api_actor.id).is_disabled
    end

    test "allows an actor to update itself without changing is_disabled", %{
      conn: conn,
      actor: api_actor
    } do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/actors/#{api_actor.id}", actor: %{"is_disabled" => false})

      assert %{"data" => %{"is_disabled" => false}} = json_response(conn, 200)
    end
  end

  defp iso8601(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp iso8601(_), do: nil
end
