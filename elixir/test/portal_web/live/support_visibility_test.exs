defmodule PortalWeb.SupportVisibilityTest do
  use PortalWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "sign-in chooser" do
    test "never lists the support provider", %{conn: conn, account: account} do
      email_otp_provider_fixture(account: account)
      firezone_support_provider_fixture(account: account)

      {:ok, _lv, html} = live(conn, ~p"/#{account.slug}/sign_in")

      refute html =~ "Firezone Support"
      refute html =~ "/support"
    end
  end

  describe "settings authentication" do
    test "does not list the support provider", %{conn: conn, account: account, actor: actor} do
      provider = firezone_support_provider_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}/settings/authentication")

      refute html =~ provider.id
    end

    test "404s on firezone_support type tampering", %{conn: conn, account: account, actor: actor} do
      provider = firezone_support_provider_fixture(account: account)
      conn = authorize_conn(conn, actor)

      assert_error_sent 404, fn ->
        live(conn, ~p"/#{account.slug}/settings/authentication/firezone_support/new")
      end

      assert_error_sent 404, fn ->
        live(conn, ~p"/#{account.slug}/settings/authentication/firezone_support/#{provider.id}/edit")
      end
    end
  end

  describe "support actor protection" do
    test "redirects away from the edit page for support actors", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      support_actor = support_actor_fixture(account: account)

      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}/actors/#{support_actor.id}/edit")

      assert to == ~p"/#{account.slug}/actors"
      assert flash["error"] =~ "cannot be edited"
    end

    test "hides edit, disable, welcome email, and danger zone for support actors", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      support_actor = support_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}/actors/#{support_actor.id}")

      refute html =~ "open_actor_edit_form"
      refute html =~ "confirm_disable_actor"
      refute html =~ "send_welcome_email"
      refute html =~ "Danger Zone"
      assert html =~ "Firezone Support"
    end
  end

  describe "support actor's own view" do
    test "shows the red signed-into-customer banner", %{conn: conn, account: account} do
      provider = firezone_support_provider_fixture(account: account)
      support_actor = support_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn_with_provider(support_actor, provider)
        |> live(~p"/#{account.slug}/sites")

      assert html =~ "You are signed into customer #{account.slug}"
      assert html =~ "End support session now"
      refute html =~ "Firezone Support is currently active and expires in"
    end
  end

  describe "support banner and topbar" do
    test "shows the banner and active pill while support is active", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = firezone_support_provider_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}/sites")

      assert html =~ "Firezone Support is currently active and expires in"
      assert html =~ "End support session now"
      assert html =~ ~s(data-expires-at="#{DateTime.to_iso8601(provider.expires_at)}")
      assert html =~ ~s(action="/#{account.slug}/support_request/end")
      assert html =~ "Support active"
      refute html =~ ">Request Support<"
    end

    test "shows the Request Support button when support is inactive", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}/sites")

      refute html =~ "Firezone Support is currently active"
      assert html =~ "Request Support"
      assert html =~ ~s(action="/#{account.slug}/support_request")
      assert html =~ "Allow Firezone Support to access this account for 24 hours"
    end
  end
end
