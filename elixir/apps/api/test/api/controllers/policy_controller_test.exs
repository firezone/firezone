defmodule API.PolicyControllerTest do
  use API.ConnCase, async: true
  alias Domain.Policies.Policy

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
      conn = get(conn, "/policies")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all policies", %{conn: conn, account: account, actor: actor} do
      policies = for _ <- 1..3, do: Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies", JSON.encode!(%{}))

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

      data_ids = Enum.map(data, & &1["id"])
      policy_ids = Enum.map(policies, & &1.id)

      assert equal_ids?(data_ids, policy_ids)
    end

    test "lists policies with limit", %{conn: conn, account: account, actor: actor} do
      policies = for _ <- 1..3, do: Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies", limit: "2")

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
      policy_ids = Enum.map(policies, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, policy_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})
      conn = get(conn, "/policies/#{policy.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single policy", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies/#{policy.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => policy.id,
                 "actor_group_id" => policy.actor_group_id,
                 "resource_id" => policy.resource_id,
                 "description" => policy.description
               }
             }
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/policies", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "error" => %{
                   "reason" => "Unprocessable Entity",
                   "validation_errors" => %{
                     "actor_group_id" => ["can't be blank"],
                     "resource_id" => ["can't be blank"]
                   }
                 }
               }
    end

    test "creates a policy with valid attrs", %{conn: conn, account: account, actor: actor} do
      resource = Fixtures.Resources.create_resource(%{account: account})
      actor_group = Fixtures.Actors.create_group(%{account: account})

      attrs = %{
        "actor_group_id" => actor_group.id,
        "resource_id" => resource.id,
        "description" => "test policy"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["actor_group_id"] == attrs["actor_group_id"]
      assert resp["data"]["resource_id"] == attrs["resource_id"]
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})
      conn = put(conn, "/policies/#{policy.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "updates a policy", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      attrs = %{"description" => "updated policy description"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["description"] == attrs["description"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})
      conn = delete(conn, "/policies/#{policy.id}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a policy", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/policies/#{policy.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => policy.id,
                 "actor_group_id" => policy.actor_group_id,
                 "resource_id" => policy.resource_id,
                 "description" => policy.description
               }
             }

      refute Repo.get(Policy, policy.id)
    end
  end
end
