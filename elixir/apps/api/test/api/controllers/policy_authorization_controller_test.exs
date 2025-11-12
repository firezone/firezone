defmodule API.PolicyAuthorizationControllerTest do
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
      conn = get(conn, "/policy_authorizations")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all policy authorizations", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      policy_authorizations =
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
        |> get("/policy_authorizations")

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)

      assert equal_ids?(data_ids, policy_authorizations_ids)
    end

    test "lists policy authorizations with range", %{
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
        |> get("/policy_authorizations",
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

    test "lists all policy authorizations for a policy", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      policy = Fixtures.Policies.create_policy(%{account: account})

      # Policy autorizations not matching filters
      for _ <- 1..3,
          do:
            Fixtures.Flows.create_flow(
              account: account,
              subject: subject
            )

      policy_authorizations =
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
        |> get("/policy_authorizations", policy_id: policy.id)

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)
      assert equal_ids?(data_ids, policy_authorizations_ids)

      data_policy_ids = Enum.map(data, & &1["policy_id"])
      policy_authorizations_policy_ids = Enum.map(policy_authorizations, & &1.policy_id)
      assert equal_ids?(data_policy_ids, policy_authorizations_policy_ids)
    end

    test "lists all policy authorizations for a resource", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      resource = Fixtures.Resources.create_resource(%{account: account})

      # Policy autorizations not matching filters
      for _ <- 1..3,
          do:
            Fixtures.Flows.create_flow(
              account: account,
              subject: subject
            )

      policy_authorizations =
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
        |> get("/policy_authorizations", resource_id: resource.id)

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)
      assert equal_ids?(data_ids, policy_authorizations_ids)

      data_resource_ids = Enum.map(data, & &1["resource_id"])
      policy_authorizations_resource_ids = Enum.map(policy_authorizations, & &1.resource_id)
      assert equal_ids?(data_resource_ids, policy_authorizations_resource_ids)
    end

    test "lists all policy authorizations for a client", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, actor: actor)

      # Policy autorizations not matching filters
      for _ <- 1..3,
          do:
            Fixtures.Flows.create_flow(
              account: account,
              subject: subject
            )

      policy_authorizations =
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
        |> get("/policy_authorizations", client_id: client.id)

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)
      assert equal_ids?(data_ids, policy_authorizations_ids)

      data_client_ids = Enum.map(data, & &1["client_id"])
      policy_authorizations_client_ids = Enum.map(policy_authorizations, & &1.client_id)
      assert equal_ids?(data_client_ids, policy_authorizations_client_ids)
    end

    test "lists all policy authorizations for an actor", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: user_actor)

      # Policy autorizations not matching filters
      for _ <- 1..3,
          do:
            Fixtures.Flows.create_flow(
              account: account,
              subject: subject
            )

      policy_authorizations =
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
        |> get("/policy_authorizations", actor_id: user_actor.id)

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)
      assert equal_ids?(data_ids, policy_authorizations_ids)

      data_client_ids = Enum.map(data, & &1["client_id"])
      policy_authorizations_client_ids = Enum.map(policy_authorizations, & &1.client_id)
      assert equal_ids?(data_client_ids, policy_authorizations_client_ids)
    end

    test "lists all policy authorizations for a gateway", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      gateway = Fixtures.Gateways.create_gateway(%{account: account})

      # Policy autorizations not matching filters
      for _ <- 1..3,
          do:
            Fixtures.Flows.create_flow(
              account: account,
              subject: subject
            )

      policy_authorizations =
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
        |> get("/policy_authorizations", gateway_id: gateway.id)

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)
      assert equal_ids?(data_ids, policy_authorizations_ids)

      data_gateway_ids = Enum.map(data, & &1["gateway_id"])
      policy_authorizations_gateway_ids = Enum.map(policy_authorizations, & &1.gateway_id)
      assert equal_ids?(data_gateway_ids, policy_authorizations_gateway_ids)
    end

    test "lists all policy authorizations with multiple filters", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      gateway = Fixtures.Gateways.create_gateway(%{account: account})

      # Policy autorizations not matching filters
      for _ <- 1..3 do
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject
        )

        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client
        )

        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          gateway: gateway
        )
      end

      policy_authorizations =
        for _ <- 1..3,
            do:
              Fixtures.Flows.create_flow(
                account: account,
                subject: subject,
                gateway: gateway,
                client: client
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policy_authorizations", gateway_id: gateway.id, client_id: client.id)

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
      policy_authorizations_ids = Enum.map(policy_authorizations, & &1.id)
      assert equal_ids?(data_ids, policy_authorizations_ids)

      data_gateway_ids = Enum.map(data, & &1["gateway_id"])
      policy_authorizations_gateway_ids = Enum.map(policy_authorizations, & &1.gateway_id)
      assert equal_ids?(data_gateway_ids, policy_authorizations_gateway_ids)

      data_client_ids = Enum.map(data, & &1["client_id"])
      policy_authorizations_client_ids = Enum.map(policy_authorizations, & &1.client_id)
      assert equal_ids?(data_client_ids, policy_authorizations_client_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      policy_authorization =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject
        )

      conn = get(conn, "/policy_authorizations/#{policy_authorization.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single policy authorization", %{
      conn: conn,
      account: account,
      actor: actor,
      subject: subject
    } do
      policy_authorization =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/policy_authorizations/#{policy_authorization.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => policy_authorization.id,
                 "policy_id" => policy_authorization.policy_id,
                 "client_id" => policy_authorization.client_id,
                 "gateway_id" => policy_authorization.gateway_id,
                 "resource_id" => policy_authorization.resource_id,
                 "token_id" => subject.token_id,
                 "inserted_at" => DateTime.to_iso8601(policy_authorization.inserted_at)
               }
             }
    end
  end
end
