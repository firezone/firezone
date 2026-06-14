defmodule PortalAPI.PolicyControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Policy

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.GroupFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/policies")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error for invalid page cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} =
               json_response(conn, 400)
    end

    test "lists all policies", %{conn: conn, account: account, actor: actor} do
      policies = for _ <- 1..3, do: policy_fixture(account: account)

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
      policies = for _ <- 1..3, do: policy_fixture(account: account)

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
      policy = policy_fixture(account: account)
      conn = get(conn, "/policies/#{policy.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns a single policy", %{conn: conn, account: account, actor: actor} do
      policy = policy_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies/#{policy.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => policy.id,
                 "group_id" => policy.group_id,
                 "resource_id" => policy.resource_id,
                 "description" => policy.description,
                 "conditions" => []
               }
             }
    end

    test "renders conditions for a policy", %{conn: conn, account: account, actor: actor} do
      policy =
        policy_with_conditions_fixture(%{
          account: account,
          conditions: [
            %{property: :remote_ip, operator: :is_in_cidr, values: ["10.0.0.0/8"]}
          ]
        })

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies/#{policy.id}")

      assert json_response(conn, 200)["data"]["conditions"] == [
               %{
                 "property" => "remote_ip",
                 "operator" => "is_in_cidr",
                 "values" => ["10.0.0.0/8"]
               }
             ]
    end

    test "returns nil group_id for orphaned policy", %{conn: conn, account: account, actor: actor} do
      policy = policy_fixture(account: account)
      policy = Repo.update!(Ecto.Changeset.change(policy, group_id: nil))

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies/#{policy.id}")

      assert json_response(conn, 200)["data"]["group_id"] == nil
    end

    test "returns not found when policy does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "create/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/policies", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies")

      assert resp = json_response(conn, 400)
      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} = resp
    end

    test "returns error on invalid attrs", %{conn: conn, actor: actor} do
      attrs = %{}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert %{
               "status" => 422,
               "validation_errors" => %{
                 "group_id" => ["can't be blank"],
                 "resource_id" => ["can't be blank"]
               }
             } = json_response(conn, 422)
    end

    test "returns validation error for malformed group_id value", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: %{"group_id" => "<no value>", "resource_id" => resource.id})

      assert %{
               "status" => 422,
               "validation_errors" => %{"group_id" => ["is invalid"]}
             } = json_response(conn, 422)
    end

    test "creates a policy with valid attrs", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id,
        "description" => "test policy"
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["group_id"] == attrs["group_id"]
      assert resp["data"]["resource_id"] == attrs["resource_id"]
      assert resp["data"]["conditions"] == []
    end

    test "creates a policy with conditions", %{conn: conn, account: account, actor: actor} do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id,
        "conditions" => [
          %{"property" => "remote_ip_location_region", "operator" => "is_in", "values" => ["US"]}
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["conditions"] == [
               %{
                 "property" => "remote_ip_location_region",
                 "operator" => "is_in",
                 "values" => ["US"]
               }
             ]
    end

    test "creates a policy with auth_provider_id and time conditions", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)
      provider_id = Ecto.UUID.generate()

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id,
        "conditions" => [
          %{"property" => "auth_provider_id", "operator" => "is_in", "values" => [provider_id]},
          %{
            "property" => "current_utc_datetime",
            "operator" => "is_in_day_of_week_time_ranges",
            "values" => ["M/09:00-17:00/America/New_York"]
          }
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert resp = json_response(conn, 201)

      assert resp["data"]["conditions"] == [
               %{
                 "property" => "auth_provider_id",
                 "operator" => "is_in",
                 "values" => [provider_id]
               },
               %{
                 "property" => "current_utc_datetime",
                 "operator" => "is_in_day_of_week_time_ranges",
                 "values" => ["M/09:00-17:00/America/New_York"]
               }
             ]
    end

    test "rejects duplicate values within a condition", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)
      provider_id = Ecto.UUID.generate()

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id,
        "conditions" => [
          %{
            "property" => "auth_provider_id",
            "operator" => "is_in",
            "values" => [provider_id, provider_id]
          }
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert json_response(conn, 422)["title"] == "Unprocessable Content"
    end

    test "rejects more than one condition per property", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id,
        "conditions" => [
          %{"property" => "remote_ip_location_region", "operator" => "is_in", "values" => ["US"]},
          %{"property" => "remote_ip_location_region", "operator" => "is_not_in", "values" => ["US"]}
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert json_response(conn, 422)["validation_errors"] == %{
               "base" => ["must not contain more than one condition per property"]
             }
    end

    test "returns validation error for invalid condition", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id,
        "conditions" => [
          %{"property" => "remote_ip", "operator" => "is_in", "values" => ["10.0.0.0/8"]}
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert json_response(conn, 422)["title"] == "Unprocessable Content"
    end

    test "sets group_idp_id when creating policy for synced group", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      resource = resource_fixture(account: account)
      synced_group = synced_group_fixture(account: account, idp_id: "synced_group_create_123")

      attrs = %{
        "group_id" => synced_group.id,
        "resource_id" => resource.id
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert json_response(conn, 201)["data"]["group_id"] == synced_group.id

      assert policy =
               Repo.get_by(Portal.Policy, group_id: synced_group.id, resource_id: resource.id)

      assert policy.group_idp_id == "synced_group_create_123"
    end

    test "returns not found when referenced resource does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => Ecto.UUID.generate()
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "returns forbidden when internet resource is not enabled for the account", %{conn: conn} do
      account = account_fixture()
      actor = api_client_fixture(account: account)
      resource = internet_resource_fixture(account: account)
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert %{
               "type" => "about:blank",
               "status" => 403,
               "detail" => "Internet resource is not enabled for this account"
             } = json_response(conn, 403)
    end

    test "creates an internet resource policy when the feature is enabled", %{conn: conn} do
      account = account_fixture(features: %{internet_resource: true})
      actor = api_client_fixture(account: account)
      resource = internet_resource_fixture(account: account)
      group = group_fixture(account: account)

      attrs = %{
        "group_id" => group.id,
        "resource_id" => resource.id
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/policies", policy: attrs)

      assert resp = json_response(conn, 201)
      assert resp["data"]["resource_id"] == resource.id
      assert resp["data"]["group_id"] == group.id
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = policy_fixture(account: account)
      conn = put(conn, "/policies/#{policy.id}", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: actor} do
      policy = policy_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}")

      assert resp = json_response(conn, 400)
      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} = resp
    end

    test "returns not found when policy does not exist", %{conn: conn, actor: actor} do
      attrs = %{"description" => "updated"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{Ecto.UUID.generate()}", policy: attrs)

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "updates a policy", %{conn: conn, account: account, actor: actor} do
      policy = policy_fixture(account: account)

      attrs = %{"description" => "updated policy description"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["description"] == attrs["description"]
    end

    test "preserves conditions when conditions are omitted", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      policy =
        policy_with_conditions_fixture(%{
          account: account,
          conditions: [%{property: :remote_ip, operator: :is_in_cidr, values: ["10.0.0.0/8"]}]
        })

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: %{"description" => "updated"})

      assert resp = json_response(conn, 200)
      assert resp["data"]["description"] == "updated"

      assert resp["data"]["conditions"] == [
               %{
                 "property" => "remote_ip",
                 "operator" => "is_in_cidr",
                 "values" => ["10.0.0.0/8"]
               }
             ]
    end

    test "updates a policy's conditions", %{conn: conn, account: account, actor: actor} do
      policy =
        policy_with_conditions_fixture(%{
          account: account,
          conditions: [%{property: :remote_ip, operator: :is_in_cidr, values: ["10.0.0.0/8"]}]
        })

      attrs = %{
        "conditions" => [
          %{"property" => "client_verified", "operator" => "is", "values" => ["true"]}
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: attrs)

      assert json_response(conn, 200)["data"]["conditions"] == [
               %{
                 "property" => "client_verified",
                 "operator" => "is",
                 "values" => ["true"]
               }
             ]
    end

    test "rejects more than one condition per property on update", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      policy = policy_fixture(account: account)

      attrs = %{
        "conditions" => [
          %{"property" => "remote_ip_location_region", "operator" => "is_in", "values" => ["US"]},
          %{"property" => "remote_ip_location_region", "operator" => "is_not_in", "values" => ["US"]}
        ]
      }

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: attrs)

      assert json_response(conn, 422)["validation_errors"] == %{
               "base" => ["must not contain more than one condition per property"]
             }
    end

    test "returns validation error for invalid group_id value", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      policy = policy_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: %{"group_id" => "<no value>"})

      assert %{
               "status" => 422,
               "validation_errors" => %{"group_id" => ["is invalid"]}
             } = json_response(conn, 422)
    end

    test "updates group_idp_id when changing to a synced group", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      policy = policy_fixture(account: account)
      synced_group = synced_group_fixture(account: account, idp_id: "synced_group_123")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: %{"group_id" => synced_group.id})

      assert json_response(conn, 200)["data"]["group_id"] == synced_group.id

      assert updated_policy = Repo.get_by(Portal.Policy, id: policy.id)
      assert updated_policy.group_idp_id == "synced_group_123"
    end

    test "clears group_idp_id when changing to a non-synced group", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      policy = policy_fixture(account: account)
      policy = Repo.update!(Ecto.Changeset.change(policy, group_idp_id: "old_synced_id"))
      static_group = group_fixture(account: account, type: :static, idp_id: nil)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/policies/#{policy.id}", policy: %{"group_id" => static_group.id})

      assert json_response(conn, 200)["data"]["group_id"] == static_group.id

      assert updated_policy = Repo.get_by(Portal.Policy, id: policy.id)
      assert updated_policy.group_idp_id == nil
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = policy_fixture(account: account)
      conn = delete(conn, "/policies/#{policy.id}", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns not found when policy does not exist", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/policies/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "deletes a policy", %{conn: conn, account: account, actor: actor} do
      policy = policy_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/policies/#{policy.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => policy.id,
                 "group_id" => policy.group_id,
                 "resource_id" => policy.resource_id,
                 "description" => policy.description,
                 "conditions" => []
               }
             }

      refute Repo.get_by(Policy, id: policy.id, account_id: policy.account_id)
    end
  end
end
