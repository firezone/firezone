defmodule FzHttpWeb.JSON.RuleControllerTest do
  use FzHttpWeb.ApiCase, async: true
  import FzHttp.GatewaysFixtures, only: [setup_default_gateway: 1]
  import FzHttp.AllowRulesFixtures
  import FzHttpWeb.ApiCase
  alias FzHttp.AllowRules

  setup :setup_default_gateway

  @allow_rule_params %{
    "destination" => "1.1.1.1/24",
    "protocol" => "udp",
    "port_range_start" => 1,
    "port_range_end" => 2
  }

  describe "GET /v0/allow_rules/:id" do
    test "shows rule" do
      conn = authed_conn()
      id = allow_rule().id
      conn = get(conn, ~p"/v0/allow_rules/#{id}")
      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end

    test "renders 404 for rule not found" do
      assert_error_sent(404, fn ->
        get(authed_conn(), ~p"/v0/allow_rules/003da73d-2dd9-4492-8136-3282843545e8")
      end)
    end

    test "renders 401 for missing authorization header" do
      rule = allow_rule()
      conn = get(unauthed_conn(), ~p"/v0/allow_rules/#{rule}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "POST /v0/allow_rules" do
    test "creates accept rule when valid" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource

      conn =
        post(conn, ~p"/v0/allow_rules",
          allow_rule: Map.merge(@allow_rule_params, %{"user_id" => user.id})
        )
        |> doc()

      assert @allow_rule_params = json_response(conn, 201)["data"]
    end

    test "returns errors when invalid" do
      params = %{"destination" => "invalid"}
      conn = post(authed_conn(), ~p"/v0/allow_rules", allow_rule: params)

      assert json_response(conn, 422)["errors"] == %{
               "destination" => ["is invalid"]
             }
    end

    test "renders 401 for missing authorization header" do
      conn = post(unauthed_conn(), ~p"/v0/allow_rules", rule: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "GET /v0/allow_rules" do
    test "lists rules" do
      for i <- 1..5, do: allow_rule(%{destination: "10.3.2.#{i}"})

      conn =
        get(authed_conn(), ~p"/v0/allow_rules")
        |> doc()

      actual =
        AllowRules.list_allow_rules()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      expected =
        json_response(conn, 200)["data"]
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert actual == expected
    end

    test "renders 401 for missing authorization header" do
      conn = get(unauthed_conn(), ~p"/v0/allow_rules")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "DELETE /v0/allow_rules/:id" do
    test "deletes rule" do
      rule = allow_rule()

      conn =
        delete(authed_conn(), ~p"/v0/allow_rules/#{rule}")
        |> doc()

      assert response(conn, 204)

      assert_error_sent(404, fn ->
        get(authed_conn(), ~p"/v0/allow_rules/#{rule}")
      end)
    end

    test "renders 404 for rule not found" do
      assert_error_sent(404, fn ->
        delete(authed_conn(), ~p"/v0/allow_rules/003da73d-2dd9-4492-8136-3282843545e8")
      end)
    end

    test "renders 401 for missing authorization header" do
      conn = delete(unauthed_conn(), ~p"/v0/allow_rules/#{allow_rule()}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
