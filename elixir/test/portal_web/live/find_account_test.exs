defmodule PortalWeb.FindAccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  describe "mount" do
    test "renders email input form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/find_account")

      assert html =~ "Find your organization&#39;s account"
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

    test "emails account sign-in links with account slugs", %{conn: conn} do
      email = "user@example.com"
      account = account_fixture()
      actor_fixture(account: account, email: email)

      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: email})
        |> render_submit()

      assert html =~ "Check your inbox"

      assert_email_sent(fn email ->
        assert email.text_body =~ "http://localhost:13100/#{account.slug}/sign_in"
        refute email.text_body =~ "http://localhost:13100/#{account.id}/sign_in"
        true
      end)
    end

    test "limits emails from one client IP across addresses", %{conn: conn} do
      Portal.Config.put_env_override(:portal, PortalWeb.PublicEmailRateLimit, per_ip_per_hour: 1)
      conn = Plug.Test.put_peer_data(conn, %{address: unique_ip(), port: 443, ssl_cert: nil})

      {:ok, lv, _html} = live(conn, ~p"/find_account")
      lv |> form("form", email_form: %{email: "first@example.com"}) |> render_submit()
      assert_email_sent(to: "first@example.com")

      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: "second@example.com"})
        |> render_submit()

      assert html =~ "Too many attempts"
      refute html =~ "Check your inbox"
      refute_email_sent()
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

  defp unique_ip do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end
end
