defmodule PortalWeb.Settings.ProfileTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/profile"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "renders profile page with actor name", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      assert html =~ actor.name
    end

    test "renders start page options", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      assert html =~ "Start Page"
      assert html =~ "Sites"
      assert html =~ "Resources"
    end

    test "saves start page preference on change", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      lv
      |> form("#preferences-form",
        actor: %{preferences: %{start_page: "resources"}}
      )
      |> render_change()

      html = render(lv)
      assert html =~ actor.name
    end
  end

  describe "sidebar wordmark link" do
    test "defaults to sites when no start page preference is set", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      assert has_element?(lv, "[data-sidebar-wordmark] a[href='#{~p"/#{account}/sites"}']")
    end

    test "links to the actor's preferred start page", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      auth_provider = Portal.AuthProviderFixtures.email_otp_provider_fixture(account: account)

      for {start_page, expected_path} <- [
            resources: ~p"/#{account}/resources",
            groups: ~p"/#{account}/groups",
            policies: ~p"/#{account}/policies",
            clients: ~p"/#{account}/clients",
            actors: ~p"/#{account}/actors",
            sites: ~p"/#{account}/sites"
          ] do
        actor
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:preferences, %Portal.Actor.Preferences{
          start_page: start_page
        })
        |> Portal.Repo.update!()

        updated_actor =
          Portal.Repo.get_by!(Portal.Actor, id: actor.id, account_id: account.id)

        {:ok, lv, _html} =
          conn
          |> authorize_conn_with_provider(updated_actor, auth_provider)
          |> live(~p"/#{account}/settings/profile")

        assert has_element?(lv, "[data-sidebar-wordmark] a[href='#{expected_path}']"),
               "expected sidebar link to #{expected_path} for start_page: #{inspect(start_page)}"
      end
    end
  end
end
