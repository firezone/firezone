defmodule FzHttpWeb.JSON.RuleControllerTest do
  use FzHttpWeb.ApiCase, async: true
  import FzHttp.RulesFixtures
  import FzHttpWeb.ApiCase

  alias FzHttp.Rules

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
      id = rule().id

      conn =
        get(authed_conn(), ~p"/v0/rules/#{id}")
        |> doc()

      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end

    test "renders 404 for rule not found" do
      assert_error_sent(404, fn ->
        get(authed_conn(), ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8")
      end)
    end

    test "renders 401 for missing authorization header" do
      rule = rule()
      conn = get(unauthed_conn(), ~p"/v0/rules/#{rule}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "POST /v0/rules" do
    test "creates accept rule when valid" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource

      conn =
        post(conn, ~p"/v0/rules", rule: Map.merge(@accept_rule_params, %{"user_id" => user.id}))
        |> doc()

      assert @accept_rule_params = json_response(conn, 201)["data"]
    end

    test "creates drop rule when valid" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource

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
      rule = rule()

      conn =
        put(authed_conn(), ~p"/v0/rules/#{rule}", rule: @accept_rule_params)
        |> doc()

      assert @accept_rule_params = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/rules/#{rule}")
      assert @accept_rule_params = json_response(conn, 200)["data"]
    end

    test "updates drop rule when valid" do
      rule = rule()
      conn = put(authed_conn(), ~p"/v0/rules/#{rule}", rule: @drop_rule_params)
      assert @drop_rule_params = json_response(conn, 200)["data"]

      conn = get(authed_conn(), ~p"/v0/rules/#{rule}")
      assert @drop_rule_params = json_response(conn, 200)["data"]
    end

    test "returns errors when invalid" do
      rule = rule()
      params = %{"action" => "invalid"}
      conn = put(authed_conn(), ~p"/v0/rules/#{rule}", rule: params)
      assert json_response(conn, 422)["errors"] == %{"action" => ["is invalid"]}
    end

    test "renders 404 for rule not found" do
      assert_error_sent(404, fn ->
        put(authed_conn(), ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8", rule: %{})
      end)
    end

    test "renders 401 for missing authorization header" do
      conn = put(unauthed_conn(), ~p"/v0/rules/#{rule()}", rule: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "GET /v0/rules" do
    test "lists rules" do
      for i <- 1..5, do: rule(%{destination: "10.3.2.#{i}"})

      conn =
        get(authed_conn(), ~p"/v0/rules")
        |> doc()

      actual =
        Rules.list_rules()
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
      rule = rule()

      conn =
        delete(authed_conn(), ~p"/v0/rules/#{rule}")
        |> doc()

      assert response(conn, 204)

      assert_error_sent(404, fn ->
        get(authed_conn(), ~p"/v0/rules/#{rule}")
      end)
    end

    test "renders 404 for rule not found" do
      assert_error_sent(404, fn ->
        delete(authed_conn(), ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8")
      end)
    end

    test "renders 401 for missing authorization header" do
      conn = delete(unauthed_conn(), ~p"/v0/rules/#{rule()}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
