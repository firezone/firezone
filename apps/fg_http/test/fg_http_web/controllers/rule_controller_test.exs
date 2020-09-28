defmodule FgHttpWeb.RuleControllerTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.Fixtures

  @valid_create_attrs %{
    destination: "1.1.1.1",
    port_number: 53,
    protocol: "udp",
    action: "accept"
  }
  @invalid_create_attrs %{
    destination: "problem"
  }
  @valid_update_attrs @valid_create_attrs
  @invalid_update_attrs @invalid_create_attrs

  describe "index" do
    setup [:create_device]

    test "list all rules", %{authed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_rule_path(conn, :index, device))

      assert html_response(test_conn, 200) =~ "Listing Rules"
    end
  end

  describe "new" do
    setup [:create_device]

    test "renders form", %{authed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_rule_path(conn, :new, device))

      assert html_response(test_conn, 200) =~ "New Rule"
    end
  end

  describe "create" do
    setup [:create_device]

    test "redirects when data is valid", %{authed_conn: conn, device: device} do
      test_conn =
        post(conn, Routes.device_rule_path(conn, :create, device), rule: @valid_create_attrs)

      assert redirected_to(test_conn) == Routes.device_rule_path(test_conn, :index, device)
    end

    test "renders edit when data is invalid", %{authed_conn: conn, device: device} do
      test_conn =
        post(conn, Routes.device_rule_path(conn, :create, device), rule: @invalid_create_attrs)

      assert html_response(test_conn, 200) =~ "New Rule"
    end
  end

  describe "edit" do
    setup [:create_rule]

    test "renders form", %{authed_conn: conn, rule: rule} do
      test_conn = get(conn, Routes.rule_path(conn, :edit, rule))

      assert html_response(test_conn, 200) =~ "Edit Rule"
    end
  end

  describe "show" do
    setup [:create_rule]

    test "renders the rule", %{authed_conn: conn, rule: rule} do
      test_conn = get(conn, Routes.rule_path(conn, :show, rule))

      assert html_response(test_conn, 200) =~ "Show Rule"
    end
  end

  describe "update" do
    setup [:create_rule]

    test "redirects to index with valid attrs", %{authed_conn: conn, rule: rule} do
      test_conn = put(conn, Routes.rule_path(conn, :update, rule), rule: @valid_update_attrs)

      assert redirected_to(test_conn) ==
               Routes.device_rule_path(test_conn, :index, rule.device_id)
    end

    test "renders edit form with invalid attrs", %{authed_conn: conn, rule: rule} do
      test_conn = put(conn, Routes.rule_path(conn, :update, rule), rule: @invalid_update_attrs)

      assert html_response(test_conn, 200) =~ "Edit Rule"
    end
  end

  describe "delete" do
    setup [:create_rule]

    test "deletes chosen rule", %{authed_conn: conn, rule: rule} do
      test_conn = delete(conn, Routes.rule_path(conn, :delete, rule))

      assert redirected_to(test_conn) == Routes.device_rule_path(conn, :index, rule.device_id)

      assert_error_sent 404, fn ->
        get(conn, Routes.rule_path(conn, :show, rule))
      end
    end
  end

  defp create_device(_) do
    device = Fixtures.device()
    {:ok, device: device}
  end

  defp create_rule(_) do
    rule = Fixtures.rule()
    {:ok, rule: rule}
  end
end
