defmodule Web.JSON.RuleControllerTest do
  use Web.ApiCase, async: true
  alias Domain.RulesFixtures
  import Web.ApiCase

  @accept_rule_params %{
    "destination" => "1.1.1.1/24",
    "action" => "accept",
    "port_type" => "udp",
    "port_range" => "1 - 2"
  }

  @drop_rule_params %{
    "destination" => "5.5.5.5/24",
    "action" => "drop",
    "port_type" => "tcp",
    "port_range" => "1 - 65000"
  }

  describe "GET /v0/rules/:id" do
    test "shows rule" do
      id = RulesFixtures.create_rule().id

      conn =
        get(authed_conn(), ~p"/v0/rules/#{id}")
        |> doc()

      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end

    test "renders 404 for rule not found" do
      conn = get(authed_conn(), ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 401 for missing authorization header" do
      rule = RulesFixtures.create_rule()
      conn = get(unauthed_conn(), ~p"/v0/rules/#{rule}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "POST /v0/rules" do
    test "creates accept rule when valid" do
      conn = authed_conn()
      {:user, user} = conn.private.guardian_default_resource.actor

      conn =
        post(conn, ~p"/v0/rules", rule: Map.merge(@accept_rule_params, %{"user_id" => user.id}))
        |> doc()

      assert @accept_rule_params = json_response(conn, 201)["data"]
    end

    test "creates drop rule when valid" do
      conn = authed_conn()
      {:user, user} = conn.private.guardian_default_resource.actor

      conn =
        post(conn, ~p"/v0/rules", rule: Map.merge(@drop_rule_params, %{"user_id" => user.id}))

      assert @drop_rule_params = json_response(conn, 201)["data"]
    end

    test "returns errors when invalid" do
      params = %{"action" => "invalid"}
      conn = post(authed_conn(), ~p"/v0/rules", rule: params)

      assert json_response(conn, 422)["errors"] == %{
               "action" => ["is invalid"],
               "destination" => ["can't be blank"]
             }
    end

    test "renders 401 for missing authorization header" do
      conn = post(unauthed_conn(), ~p"/v0/rules", rule: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "PUT /v0/rules/:id" do
    test "updates accept rule when valid" do
      rule = RulesFixtures.create_rule()

      conn =
        put(authed_conn(), ~p"/v0/rules/#{rule}", rule: @accept_rule_params)
        |> doc()

      assert @accept_rule_params = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/rules/#{rule}")
      assert @accept_rule_params = json_response(conn, 200)["data"]
    end

    test "updates drop rule when valid" do
      rule = RulesFixtures.create_rule()
      conn = put(authed_conn(), ~p"/v0/rules/#{rule}", rule: @drop_rule_params)
      assert @drop_rule_params = json_response(conn, 200)["data"]

      conn = get(authed_conn(), ~p"/v0/rules/#{rule}")
      assert @drop_rule_params = json_response(conn, 200)["data"]
    end

    test "returns errors when invalid" do
      rule = RulesFixtures.create_rule()
      params = %{"action" => "invalid"}
      conn = put(authed_conn(), ~p"/v0/rules/#{rule}", rule: params)
      assert json_response(conn, 422)["errors"] == %{"action" => ["is invalid"]}
    end

    test "renders 404 for rule not found" do
      conn = put(authed_conn(), ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8", rule: %{})
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 401 for missing authorization header" do
      conn = put(unauthed_conn(), ~p"/v0/rules/#{RulesFixtures.create_rule()}", rule: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "GET /v0/rules" do
    test "lists rules" do
      rules =
        for i <- 1..5 do
          RulesFixtures.create_rule(%{destination: "10.3.2.#{i}"})
        end

      conn =
        get(authed_conn(), ~p"/v0/rules")
        |> doc()

      actual =
        rules
        |> Enum.map(& &1.id)
        |> Enum.sort()

      expected =
        json_response(conn, 200)["data"]
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert actual == expected
    end

    test "renders 401 for missing authorization header" do
      conn = get(unauthed_conn(), ~p"/v0/rules")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "DELETE /v0/rules/:id" do
    test "deletes rule" do
      rule = RulesFixtures.create_rule()

      conn =
        delete(authed_conn(), ~p"/v0/rules/#{rule}")
        |> doc()

      assert response(conn, 204)

      conn = get(authed_conn(), ~p"/v0/rules/#{rule}")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 404 for rule not found" do
      conn = delete(authed_conn(), ~p"/v0/rules/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 401 for missing authorization header" do
      conn = delete(unauthed_conn(), ~p"/v0/rules/#{RulesFixtures.create_rule()}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
