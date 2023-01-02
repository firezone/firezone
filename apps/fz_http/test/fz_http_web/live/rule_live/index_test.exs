defmodule FzHttpWeb.RuleLive.IndexTest do
  alias FzHttp.Gateways
  use FzHttpWeb.ConnCase, async: true

  describe "allowlist" do
    setup :create_rule

    @destination "1.2.3.4"
    @allow_params %{"allow_rule" => %{"destination" => @destination}}

    test "adds to allowlist", %{admin_conn: conn} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#rule-form")
        |> render_submit(@allow_params)

      assert test_view =~ @destination
    end

    test "validation fails", %{admin_conn: conn, rule: _rule} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#rule-form")
        |> render_submit(%{
          "allow_rule" => %{
            "destination" => "not a valid destination"
          }
        })

      assert test_view =~ "is invalid"

      valid_view =
        view
        |> form("#rule-form")
        |> render_submit(%{
          "allow_rule" => %{
            "destination" => "::1"
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

  describe "adding scoped rules" do
    setup :create_user

    @destination "1.2.3.4"

    test "adds allow", %{admin_conn: conn, user: user} do
      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      params = %{
        "allow_rule" => %{
          "destination" => @destination,
          "user_id" => user.uuid,
          "gateway_id" => Gateways.get_gateway!().id
        }
      }

      view |> form("#rule-form") |> render_submit(params)

      accept_table =
        view
        |> element("#rules")
        |> render()

      assert accept_table =~ @destination
      assert accept_table =~ user.email
    end
  end

  describe "removing scoped rules" do
    @destination "1.2.3.4"

    test "removes allow", %{admin_conn: conn} do
      {:ok, rule: rule, user: user} = create_rule_with_user(%{destination: @destination})

      path = ~p"/rules"
      {:ok, view, _html} = live(conn, path)

      view |> element("a[phx-value-rule_id=#{rule.id}]") |> render_click()

      accept_table =
        view
        |> element("#rules")
        |> render()

      refute accept_table =~ @destination
      refute accept_table =~ user.email
    end
  end
end
