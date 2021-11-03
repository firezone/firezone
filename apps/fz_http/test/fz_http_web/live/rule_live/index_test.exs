defmodule FzHttpWeb.RuleLive.IndexTest do
  use FzHttpWeb.ConnCase, async: true

  describe "allowlist" do
    setup :create_accept_rule

    @destination "1.2.3.4"
    @allow_params %{"rule" => %{"action" => "accept", "destination" => @destination}}

    test "adds to allowlist", %{authed_conn: conn} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#accept-form")
        |> render_submit(@allow_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{authed_conn: conn, rule: _rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#accept-form")
        |> render_submit(%{
          "rule" => %{
            "destination" => "not a valid destination",
            "action" => "accept"
          }
        })

      assert test_view =~ "is invalid"

      valid_view =
        view
        |> form("#accept-form")
        |> render_submit(%{
          "rule" => %{
            "destination" => "::1",
            "action" => "accept"
          }
        })

      refute valid_view =~ "is invalid"
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
    setup :create_drop_rule

    @destination "1.2.3.4"
    @deny_params %{"rule" => %{"action" => "drop", "destination" => @destination}}

    test "adds to denylist", %{authed_conn: conn, rule: _rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#drop-form")
        |> render_submit(@deny_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{authed_conn: conn, rule: _rule} do
      path = Routes.rule_index_path(conn, :index)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#drop-form")
        |> render_submit(%{
          "rule" => %{
            "destination" => "not a valid destination",
            "action" => "drop"
          }
        })

      assert test_view =~ "is invalid"
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
