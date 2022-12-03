defmodule FzHttpWeb.JSON.AllowRuleControllerTest do
  use FzHttpWeb.APICase
  import FzHttp.GatewaysFixtures, only: [setup_default_gateway: 1]

  setup :setup_default_gateway

  @rule_params %{
    "destination" => "5.5.5.5/24"
  }

  describe "show rule" do
    setup :create_rule

    test "shows rule", %{conn: conn, rule: %{id: id}} do
      conn = get(conn, ~p"/v1/allow_rules/#{id}")
      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end
  end

  describe "create rule" do
    @tag params: @rule_params
    test "creates rule", %{conn: conn, unprivileged_user: user, params: params} do
      conn =
        post(conn, ~p"/v1/allow_rules", allow_rule: Map.merge(params, %{"user_id" => user.uuid}))

      assert @rule_params = json_response(conn, 201)["data"]
    end
  end

  describe "list rules" do
    setup :create_rules

    test "lists rules", %{conn: conn, rules: rules} do
      conn = get(conn, ~p"/v1/allow_rules")
      assert length(json_response(conn, 200)["data"]) == length(rules)
    end
  end

  describe "delete rule" do
    setup :create_rule

    test "deletes rule", %{conn: conn, rule: rule} do
      conn = delete(conn, ~p"/v1/allow_rules/#{rule}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v1/allow_rules/#{rule}")
      end
    end
  end
end
