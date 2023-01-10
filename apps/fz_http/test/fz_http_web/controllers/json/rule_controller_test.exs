defmodule FzHttpWeb.JSON.RuleControllerTest do
  use FzHttpWeb.ApiCase, async: true
  import FzHttpWeb.ApiCase

  describe "show rule" do
    test "shows rule" do
      conn = get(authed_conn(), ~p"/v0/rules/0")
      assert response(conn, 400)
    end
  end

  describe "create rule" do
    test "creates rule" do
      conn = post(authed_conn(), ~p"/v0/rules", rule: %{"user_id" => 0})
      assert response(conn, 400)
    end
  end

  describe "list rules" do
    test "lists rules" do
      conn = get(authed_conn(), ~p"/v0/rules")
      assert response(conn, 400)
    end
  end

  describe "delete rule" do
    test "deletes rule" do
      conn = delete(authed_conn(), ~p"/v0/rules/0")
      assert response(conn, 400)
    end
  end

  describe "update rule" do
    test "deletes rule" do
      conn = put(authed_conn(), ~p"/v0/rules/0")
      assert response(conn, 400)
    end
  end
end
