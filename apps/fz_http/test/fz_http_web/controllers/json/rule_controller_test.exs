defmodule FzHttpWeb.JSON.RuleControllerTest do
  use FzHttpWeb.ConnCase, async: true, api: true

  @rule_params %{
    "destination" => "5.5.5.5/24",
    "action" => "accept",
    "port_type" => "tcp",
    "port_range" => "1 - 65000"
  }

  describe "show rule" do
    setup :create_rule

    test "shows rule", %{api_conn: conn, rule: %{id: id}} do
      conn = get(conn, ~p"/v1/rules/#{id}")
      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end
  end

  describe "create rule" do
    @tag params: @rule_params
    test "creates rule", %{api_conn: conn, unprivileged_user: user, params: params} do
      conn = post(conn, ~p"/v1/rules", rule: Map.merge(params, %{"user_id" => user.id}))
      assert @rule_params = json_response(conn, 201)["data"]
    end
  end

  describe "update rule" do
    setup :create_rule

    @tag params: @rule_params
    test "updates rule", %{api_conn: conn, params: params, rule: %{id: id}} do
      conn = put(conn, ~p"/v1/rules/#{id}", rule: params)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v1/rules/#{id}")

      assert @rule_params = json_response(conn, 200)["data"]
    end
  end

  describe "list rules" do
    setup :create_rules

    test "lists rules", %{api_conn: conn, rules: rules} do
      conn = get(conn, ~p"/v1/rules")
      assert length(json_response(conn, 200)["data"]) == length(rules)
    end
  end

  describe "delete rule" do
    setup :create_rule

    test "deletes rule", %{api_conn: conn, rule: rule} do
      conn = delete(conn, ~p"/v1/rules/#{rule}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v1/rules/#{rule}")
      end
    end
  end
end
