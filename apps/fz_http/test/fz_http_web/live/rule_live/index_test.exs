defmodule FzHttpWeb.RuleLive.IndexTest do
  use FzHttpWeb.ConnCase, async: true

  describe "allowlist" do
    setup :create_accept_rule

    @destination "1.2.3.4"
    @allow_params %{"rule" => %{"action" => "accept", "destination" => @destination}}

    test "adds to allowlist", %{admin_conn: conn} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#accept-form")
        |> render_submit(@allow_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{admin_conn: conn, rule: _rule} do
      path = ~p"/rules"
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

    test "removes from allowlist", %{admin_conn: conn, rule: rule} do
      path = ~p"/rules"
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

    test "adds to denylist", %{admin_conn: conn, rule: _rule} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#drop-form")
        |> render_submit(@deny_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{admin_conn: conn, rule: _rule} do
      path = ~p"/rules"
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

    test "removes from denylist", %{admin_conn: conn, rule: rule} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("a[phx-value-rule_id=#{rule.id}]")
        |> render_click()

      refute test_view =~ "#{rule.destination}"
    end
  end

  describe "adding scoped rules" do
    setup :create_user

    @destination "1.2.3.4"

    test "adds allow", %{admin_conn: conn, user: user} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      params = %{
        "rule" => %{
          "action" => "accept",
          "destination" => @destination,
          "user_id" => user.id
        }
      }

      view |> form("#accept-form") |> render_submit(params)

      accept_table =
        view
        |> element("#accept-rules")
        |> render()

      assert accept_table =~ @destination
      assert accept_table =~ user.email
    end

    test "adds deny", %{admin_conn: conn, user: user} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      params = %{
        "rule" => %{
          "action" => "drop",
          "destination" => @destination,
          "user_id" => user.id
        }
      }

      view |> form("#drop-form") |> render_submit(params)

      drop_table =
        view
        |> element("#drop-rules")
        |> render()

      assert drop_table =~ @destination
      assert drop_table =~ user.email
    end
  end

  describe "removing scoped rules" do
    @destination "1.2.3.4"

    test "removes allow", %{admin_conn: conn} do
      {:ok, rule: rule, user: user} =
        create_rule_with_user(%{action: "accept", destination: @destination})

      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      view |> element("a[phx-value-rule_id=#{rule.id}]") |> render_click()

      accept_table =
        view
        |> element("#accept-rules")
        |> render()

      refute accept_table =~ @destination
      refute accept_table =~ user.email
    end

    test "removes deny", %{admin_conn: conn} do
      {:ok, rule: rule, user: user} =
        create_rule_with_user(%{action: "drop", destination: @destination})

      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      view |> element("a[phx-value-rule_id=#{rule.id}]") |> render_click()

      drop_table =
        view
        |> element("#drop-rules")
        |> render()

      refute drop_table =~ @destination
      refute drop_table =~ user.email
    end
  end
end
