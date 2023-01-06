defmodule FzHttpWeb.JSON.RuleControllerTest do
  use FzHttpWeb.ApiCase, async: true

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

  describe "[authed] GET /v0/rules/:id" do
    setup _tags, do: {:ok, conn: authed_conn()}
    setup :create_rule

    test "shows rule", %{conn: conn, rule: %{id: id}} do
      conn = get(conn, ~p"/v0/rules/#{id}")
      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end

    test "renders 404 for rule not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8")
      end
    end
  end

  describe "[authed] POST /v0/rules" do
    setup _tags, do: {:ok, conn: authed_conn()}

    @tag params: @accept_rule_params
    test "creates accept rule when valid", %{conn: conn, params: params} do
      user = conn.private.guardian_default_resource
      conn = post(conn, ~p"/v0/rules", rule: Map.merge(params, %{"user_id" => user.id}))
      assert @accept_rule_params = json_response(conn, 201)["data"]
    end

    @tag params: @drop_rule_params
    test "creates drop rule when valid", %{conn: conn, params: params} do
      user = conn.private.guardian_default_resource
      conn = post(conn, ~p"/v0/rules", rule: Map.merge(params, %{"user_id" => user.id}))
      assert @drop_rule_params = json_response(conn, 201)["data"]
    end

    @tag params: %{action: :invalid}
    test "returns errors when invalid", %{conn: conn, params: params} do
      conn = post(conn, ~p"/v0/rules", rule: params)

      assert json_response(conn, 422)["errors"] == %{
               "action" => ["is invalid"],
               "destination" => ["can't be blank"]
             }
    end
  end

  describe "[authed] PUT /v0/rules/:id" do
    setup :create_rule
    setup _tags, do: {:ok, conn: authed_conn()}

    @tag params: @accept_rule_params
    test "updates accept rule when valid", %{conn: conn, params: params, rule: %{id: id}} do
      conn = put(conn, ~p"/v0/rules/#{id}", rule: params)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/rules/#{id}")

      assert @accept_rule_params = json_response(conn, 200)["data"]
    end

    @tag params: @drop_rule_params
    test "updates drop rule when valid", %{conn: conn, params: params, rule: %{id: id}} do
      conn = put(conn, ~p"/v0/rules/#{id}", rule: params)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/rules/#{id}")

      assert @drop_rule_params = json_response(conn, 200)["data"]
    end

    @tag params: %{action: :invalid}
    test "returns errors when invalid", %{conn: conn, rule: rule, params: params} do
      conn = put(conn, ~p"/v0/rules/#{rule}", rule: params)
      assert json_response(conn, 422)["errors"] == %{"action" => ["is invalid"]}
    end

    test "renders 404 for rule not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        put(conn, ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8", rule: %{})
      end
    end
  end

  describe "[authed] GET /v0/rules" do
    setup :create_rules
    setup _tags, do: {:ok, conn: authed_conn()}

    test "lists rules", %{conn: conn, rules: rules} do
      conn = get(conn, ~p"/v0/rules")
      assert length(json_response(conn, 200)["data"]) == length(rules)
    end
  end

  describe "[authed] DELETE /v0/rules/:id" do
    setup :create_rule
    setup _tags, do: {:ok, conn: authed_conn()}

    test "deletes rule", %{conn: conn, rule: rule} do
      conn = delete(conn, ~p"/v0/rules/#{rule}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/rules/#{rule}")
      end
    end

    test "renders 404 for rule not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        delete(conn, ~p"/v0/rules/003da73d-2dd9-4492-8136-3282843545e8")
      end
    end
  end

  describe "[unauthed] GET /v0/rules/:id" do
    setup _tags, do: {:ok, conn: unauthed_conn()}
    setup :create_rule

    test "renders 401 for missing authorization header", %{conn: conn, rule: rule} do
      conn = get(conn, ~p"/v0/rules/#{rule}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] POST /v0/rules" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = post(conn, ~p"/v0/rules", rule: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] GET /v0/rules" do
    setup :create_rules
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = get(conn, ~p"/v0/rules")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] PUT /v0/rules/:id" do
    setup :create_rule
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn, rule: rule} do
      conn = put(conn, ~p"/v0/rules/#{rule}", rule: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] DELETE /v0/rules/:id" do
    setup :create_rule
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn, rule: rule} do
      conn = delete(conn, ~p"/v0/rules/#{rule}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
