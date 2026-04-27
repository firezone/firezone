defmodule PortalWeb.FindAccountTest do
  use PortalWeb.ConnCase, async: true

  describe "mount" do
    test "renders email input form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/find_account")

      assert html =~ "Find your company&#39;s account"
      assert html =~ "Work email"
      assert html =~ "Find"
    end
  end

  describe "validate_email" do
    test "shows validation error for invalid email format", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: "not-an-email"})
        |> render_change()

      assert html =~ "is an invalid email address"
    end
  end

  describe "submit_email" do
    test "valid email transitions to email sent step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: "user@example.com"})
        |> render_submit()

      assert html =~ "Check your inbox"
      assert html =~ "user@example.com"
    end

    test "invalid email stays on form with error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: ""})
        |> render_submit()

      refute html =~ "Check your inbox"
    end
  end
end
