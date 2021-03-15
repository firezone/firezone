defmodule FgHttpWeb.RuleControllerTest do
  use FgHttpWeb.ConnCase, async: true

  # import FgHttp.TestHelpers
  #
  # @valid_create_attrs %{
  #   destination: "1.1.1.1",
  #   action: "allow"
  # }
  # @invalid_create_attrs %{
  #   destination: "problem"
  # }
  #
  # describe "create" do
  #   setup [:create_device]
  #
  #   test "redirects when data is valid", %{authed_conn: conn, device: device} do
  #     test_conn =
  #       post(conn, Routes.device_rule_path(conn, :create, device), rule: @valid_create_attrs)
  #
  #     assert redirected_to(test_conn) == Routes.device_rule_path(test_conn, :index, device)
  #   end
  #
  #   test "renders edit when data is invalid", %{authed_conn: conn, device: device} do
  #     test_conn =
  #       post(conn, Routes.device_rule_path(conn, :create, device), rule: @invalid_create_attrs)
  #
  #     assert html_response(test_conn, 200) =~ "New Rule"
  #   end
  # end
  #
  # describe "delete" do
  #   setup [:create_rule]
  #
  #   test "deletes chosen rule", %{authed_conn: conn, rule: rule} do
  #     test_conn = delete(conn, Routes.rule_path(conn, :delete, rule))
  #
  #     assert redirected_to(test_conn) == Routes.device_rule_path(conn, :index, rule.device_id)
  #
  #     assert_error_sent 404, fn ->
  #       get(conn, Routes.rule_path(conn, :show, rule))
  #     end
  #   end
  # end
end
