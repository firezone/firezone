defmodule API.FlowControllerTest do
  use API.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, "/flows")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all flows", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      flows =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/flows")

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
      flows_ids = Enum.map(flows, & &1.id)

      assert equal_ids?(data_ids, flows_ids)
    end

    test "lists flows with range", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      for _ <- 1..3,
          do:
            Fixtures.Flows.create_flow(
              account: account,
              subject: subject
            )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/flows",
          min_datetime: "2025-01-01T00:00:00Z",
          max_datetime: "2025-01-02T00:00:00Z"
        )

      assert %{
               "data" => [],
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert count == 0
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)
    end
  end

  describe "index_for_policy/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      policy = Fixtures.Policies.create_policy(%{account: account})

      conn = get(conn, "/policies/#{policy.id}/flows")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all flows for a policy", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      policy = Fixtures.Policies.create_policy(%{account: account})

      flows =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject,
                policy: policy
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policies/#{policy.id}/flows")

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
      flows_ids = Enum.map(flows, & &1.id)
      assert equal_ids?(data_ids, flows_ids)

      data_policy_ids = Enum.map(data, & &1["policy_id"])
      flows_policy_ids = Enum.map(flows, & &1.policy_id)
      assert equal_ids?(data_policy_ids, flows_policy_ids)
    end
  end

  describe "index_for_resource/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      resource = Fixtures.Resources.create_resource(%{account: account})

      conn = get(conn, "/resources/#{resource.id}/flows")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all flows for a resource", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(%{account: account})

      flows =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject,
                resource: resource
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{resource.id}/flows")

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
      flows_ids = Enum.map(flows, & &1.id)
      assert equal_ids?(data_ids, flows_ids)

      data_resource_ids = Enum.map(data, & &1["resource_id"])
      flows_resource_ids = Enum.map(flows, & &1.resource_id)
      assert equal_ids?(data_resource_ids, flows_resource_ids)
    end
  end

  describe "index_for_client/2" do
    test "returns error when not authorized", %{conn: conn, account: account, actor: actor} do
      client = Fixtures.Clients.create_client(account: account, actor: actor)

      conn = get(conn, "/clients/#{client.id}/flows")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all flows for a client", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, actor: actor)

      flows =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject,
                client: client
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/clients/#{client.id}/flows")

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
      flows_ids = Enum.map(flows, & &1.id)
      assert equal_ids?(data_ids, flows_ids)

      data_client_ids = Enum.map(data, & &1["client_id"])
      flows_client_ids = Enum.map(flows, & &1.client_id)
      assert equal_ids?(data_client_ids, flows_client_ids)
    end
  end

  describe "index_for_actor/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

      conn = get(conn, "/actors/#{user_actor.id}/flows")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all flows for an actor", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: user_actor)

      flows =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject,
                client: client
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{user_actor.id}/flows")

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
      flows_ids = Enum.map(flows, & &1.id)
      assert equal_ids?(data_ids, flows_ids)

      data_client_ids = Enum.map(data, & &1["client_id"])
      flows_client_ids = Enum.map(flows, & &1.client_id)
      assert equal_ids?(data_client_ids, flows_client_ids)
    end
  end

  describe "index_for_gateway/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      gateway_group = Fixtures.Gateways.create_group(account: account)
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})

      conn = get(conn, "/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}/flows")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all flows for a gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      gateway_group = Fixtures.Gateways.create_group(account: account)
      gateway = Fixtures.Gateways.create_gateway(%{account: account, group: gateway_group})

      flows =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject,
                gateway: gateway
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/gateway_groups/#{gateway_group.id}/gateways/#{gateway.id}/flows")

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
      flows_ids = Enum.map(flows, & &1.id)
      assert equal_ids?(data_ids, flows_ids)

      data_gateway_ids = Enum.map(data, & &1["gateway_id"])
      flows_gateway_ids = Enum.map(flows, & &1.gateway_id)
      assert equal_ids?(data_gateway_ids, flows_gateway_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject
        )

      conn = get(conn, "/flows/#{flow.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single flow", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/flows/#{flow.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => flow.id,
                 "policy_id" => flow.policy_id,
                 "client_id" => flow.client_id,
                 "gateway_id" => flow.gateway_id,
                 "resource_id" => flow.resource_id,
                 "token_id" => subject.token_id,
                 "inserted_at" => DateTime.to_iso8601(flow.inserted_at)
               }
             }
    end
  end
end
