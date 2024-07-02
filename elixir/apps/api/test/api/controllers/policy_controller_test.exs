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

  describe "index" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/v1/policies")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "lists all policies", %{conn: conn, account: account, actor: actor} do
      policies = for _ <- 1..3, do: Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/policies", Jason.encode!(%{}))

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
      policy_ids = Enum.map(policies, & &1.id) |> MapSet.new()

      assert MapSet.equal?(data_ids, policy_ids)
    end

    test "lists policies with limit", %{conn: conn, account: account, actor: actor} do
      policies = for _ <- 1..3, do: Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/policies", limit: "2")

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

  describe "show" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})
      conn = get(conn, "/v1/policies/#{policy.id}")
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns a single policy", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/v1/policies/#{policy.id}")

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

  describe "create" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/v1/policies", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "returns errors on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/policies", policy: attrs)

      assert resp = json_response(conn, 422)

      assert resp ==
               %{
                 "errors" => %{
                   "actor_group_id" => ["can't be blank"],
                   "resource_id" => ["can't be blank"]
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
        |> post("/v1/policies", policy: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["actor_group_id"] == attrs["actor_group_id"]
      assert resp["data"]["resource_id"] == attrs["resource_id"]
    end
  end

  describe "update" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})
      conn = put(conn, "/v1/policies/#{policy.id}", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "updates a policy", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      attrs = %{"description" => "updated policy description"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/v1/policies/#{policy.id}", policy: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["description"] == attrs["description"]
    end
  end

  describe "delete" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})
      conn = delete(conn, "/v1/policies/#{policy.id}", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "deletes a policy", %{conn: conn, account: account, actor: actor} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/v1/policies/#{policy.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => policy.id,
                 "actor_group_id" => policy.actor_group_id,
                 "resource_id" => policy.resource_id,
                 "description" => policy.description
               }
             }

      assert {:error, :not_found} ==
               Policy.Query.not_deleted()
               |> Policy.Query.by_id(policy.id)
               |> Repo.fetch(Policy.Query)
    end
  end
end
