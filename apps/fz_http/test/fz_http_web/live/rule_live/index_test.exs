defmodule FzHttpWeb.RuleLive.IndexTest do
  use FzHttpWeb.ConnCase, async: true

  describe "allowlist" do
    setup :create_allow_rule

    @destination "1.2.3.4"
    @allow_params %{"rule" => %{"action" => "allow", "destination" => @destination}}

    test "adds to allowlist", %{authed_conn: conn, rule: rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#allow-form")
        |> render_submit(@allow_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{authed_conn: conn, rule: rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#allow-form")
        |> render_submit(%{
          "rule" => %{
            "destination" => @destination,
            "action" => "allow"
          }
        })

      refute test_view =~ @destination
    end

    test "removes from allowlist", %{authed_conn: conn, rule: rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("a[phx-value-rule_id=#{rule.id}]")
        |> render_click()

      refute test_view =~ "#{rule.destination}"
    end
  end

  describe "denylist" do
    setup :create_deny_rule

    @destination "1.2.3.4"
    @deny_params %{"rule" => %{"action" => "deny", "destination" => @destination}}

    test "adds to denylist", %{authed_conn: conn, rule: rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#deny-form")
        |> render_submit(@deny_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{authed_conn: conn, rule: rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#allow-form")
        |> render_submit(%{
          "rule" => %{
            "destination" => "invalid",
            "action" => "deny"
          }
        })

      refute test_view =~ @destination
    end

    test "removes from denylist", %{authed_conn: conn, rule: rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("a[phx-value-rule_id=#{rule.id}]")
        |> render_click()

      refute test_view =~ "#{rule.destination}"
    end
  end
end
