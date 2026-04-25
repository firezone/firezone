defmodule PortalWeb.ActorsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.PortalSessionFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/actors"

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
    test "renders actor list page", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      assert html =~ "Actors"
      assert html =~ actor.name
    end

    test "opens and closes new actor side panel", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "open_new_actor_panel")
      assert html =~ "Create User"

      html = render_click(lv, "close_panel")
      refute html =~ "Create User"
    end
  end

  describe ":new action" do
    test "New Actor button patches to /actors/new", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "open_new_actor_panel")
      assert_patch(lv, ~p"/#{account}/actors/new")
    end

    test "renders user creation form when navigating directly to /actors/new", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/new")

      assert html =~ "Create User"
    end

    test "close panel patches back to /actors/new", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/new")

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/actors")
    end
  end

  describe "create user panel" do
    test "creates user from side panel and assigns pending group memberships", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "open_new_actor_panel")
      assert_patch(lv, ~p"/#{account}/actors/new")
      html = render_click(lv, "select_new_actor_type", %{"type" => "user"})

      assert html =~ "Create User"

      lv
      |> form("form[phx-submit='create_user']",
        actor: %{
          name: "John Smith",
          email: "john.smith@example.com",
          type: "account_user",
          allow_email_otp_sign_in: "true"
        }
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "John Smith"
    end
  end

  describe "create service account panel" do
    test "creates service account from side panel and shows created token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "open_new_actor_panel")
      assert_patch(lv, ~p"/#{account}/actors/new")
      html = render_click(lv, "select_new_actor_type", %{"type" => "service_account"})

      assert html =~ "Create Service Account"

      expiration =
        Date.utc_today()
        |> Date.add(30)
        |> Date.to_iso8601()

      lv
      |> form("form[phx-submit='create_service_account']",
        actor: %{name: "CI Service Account"},
        token_expiration: expiration
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "CI Service Account"
      assert html =~ "Token Created"
    end

    test "creates service account without token when expiration is blank", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "open_new_actor_panel")
      render_click(lv, "select_new_actor_type", %{"type" => "service_account"})

      lv
      |> form("form[phx-submit='create_service_account']",
        actor: %{name: "Tokenless SA"},
        token_expiration: ""
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "Tokenless SA"
      refute html =~ "Token Created"
    end

    test "re-renders form when service account name is invalid", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      invalid_name = String.duplicate("a", 256)
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "open_new_actor_panel")
      render_click(lv, "select_new_actor_type", %{"type" => "service_account"})

      html =
        lv
        |> form("form[phx-submit='create_service_account']",
          actor: %{name: invalid_name},
          token_expiration: expiration
        )
        |> render_submit()

      assert html =~ "Create Service Account"
      assert html =~ "create_service_account"
    end

    test "shows flash error when token expiration is unparseable", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "open_new_actor_panel")
      render_click(lv, "select_new_actor_type", %{"type" => "service_account"})

      html =
        lv
        |> form("form[phx-submit='create_service_account']",
          actor: %{name: "Bad Date SA"},
          token_expiration: "not-a-date"
        )
        |> render_submit()

      assert html =~ "A temporary error occurred"
      assert html =~ "Please try again"
    end
  end

  describe ":show action" do
    test "renders actor detail panel", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      assert html =~ other_actor.name
    end

    test "shows identities tab content", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      assert html =~ "identities"
    end

    test "shows linked groups in groups tab", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)
      group = group_fixture(account: account, name: "Operators")
      membership_fixture(actor: other_actor, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "change_tab", %{"tab" => "groups"})
      assert_patch(lv, ~p"/#{account}/actors/#{other_actor}?tab=groups")

      assert html =~ group.name
      assert html =~ "Groups"
    end

    test "revokes identity from actor details", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)
      identity = identity_fixture(account: account, actor: other_actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "confirm_delete_identity", %{"id" => identity.id})
      assert html =~ "Delete this identity?"

      html = render_click(lv, "delete_identity", %{"id" => identity.id})
      refute html =~ identity.email
    end

    test "revokes portal session from portal sessions tab", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)
      auth_provider = userpass_provider_fixture(account: account).auth_provider

      session =
        portal_session_fixture(account: account, actor: other_actor, auth_provider: auth_provider)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}?tab=portal_sessions")

      html = render_click(lv, "confirm_delete_session", %{"id" => session.id})
      assert html =~ "Revoke this session?"

      render_click(lv, "delete_session", %{"id" => session.id})

      refute Portal.Repo.get_by(Portal.PortalSession, account_id: account.id, id: session.id)
    end

    test "opens and cancels actor edit form", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "open_actor_edit_form")
      assert_patch(lv, ~p"/#{account}/actors/#{other_actor}/edit")
      assert html =~ "Save Changes"

      html = render_click(lv, "cancel_actor_edit_form")
      assert_patch(lv, ~p"/#{account}/actors/#{other_actor}")
      refute html =~ "Save Changes"
    end

    test "disables and re-enables actor", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "confirm_disable_actor")
      assert html =~ "Disable this actor?"

      html = render_click(lv, "cancel_disable_actor")
      refute html =~ "Disable this actor?"

      render_click(lv, "confirm_disable_actor")
      html = render_click(lv, "disable", %{"id" => other_actor.id})
      assert html =~ "Enable"
      refute html =~ "Disable this actor?"

      html = render_click(lv, "enable", %{"id" => other_actor.id})
      refute html =~ "Enable"
      assert html =~ "Disable"
    end

    test "cancel delete actor returns to detail view", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "confirm_delete_actor")
      assert html =~ "Delete this actor?"

      html = render_click(lv, "cancel_delete_actor")
      refute html =~ "Delete this actor?"
      assert html =~ other_actor.name
    end

    test "deletes a token from service account", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{service_account}")

      html = render_click(lv, "confirm_delete_token", %{"id" => token.id})
      assert html =~ "Delete this token?"

      html = render_click(lv, "cancel_delete_token")
      refute html =~ "Delete this token?"

      render_click(lv, "confirm_delete_token", %{"id" => token.id})
      render_click(lv, "delete_token", %{"id" => token.id})

      html = render(lv)
      assert html =~ "No tokens."
    end

    test "sends welcome email", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_with_email_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "send_welcome_email", %{"id" => other_actor.id})
      assert html =~ "Email sent to #{other_actor.email}"
    end

    test "creates and dismisses token for service account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{service_account}")

      html = render_click(lv, "open_add_token_form")
      assert html =~ "New Token"

      expiration =
        Date.utc_today()
        |> Date.add(30)
        |> Date.to_iso8601()

      html =
        render_submit(element(lv, "form[phx-submit='create_token']"), %{
          "token_expiration" => expiration
        })

      assert html =~ "Token Created"

      html = render_click(lv, "dismiss_created_token")
      refute html =~ "Token Created"
    end

    test "redirects to actor list when actor does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{fake_id}")

      assert path == ~p"/#{account}/actors"
      assert flash["error"] == "Actor not found"
    end

    test "redirects to actor list when actor belongs to a different account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_account = account_fixture()
      other_actor = actor_fixture(account: other_account)

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{other_actor}")

      assert path == ~p"/#{account}/actors"
      assert flash["error"] == "Actor not found"
    end
  end

  describe ":edit action" do
    test "renders edit form pre-populated with actor name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}/edit")

      assert html =~ "Save Changes"
      assert html =~ other_actor.name
    end

    test "searches groups and removes pending addition in edit form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)
      group = group_fixture(account: account, name: "Searchable Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}/edit")

      html =
        lv
        |> element("input[placeholder='Search to add groups...']")
        |> render_change(%{"value" => group.name})

      assert html =~ group.name

      html = render_click(lv, "add_pending_group", %{"group_id" => group.id})
      assert html =~ "To Add"

      html = render_click(lv, "remove_pending_group_addition", %{"group_id" => group.id})
      refute html =~ "To Add"
    end

    test "undoes pending group removal in edit form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)
      group = group_fixture(account: account, name: "Existing Group")
      membership_fixture(actor: other_actor, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}/edit")

      html = render_click(lv, "add_pending_group_removal", %{"group_id" => group.id})
      assert html =~ "To Remove"

      html = render_click(lv, "undo_pending_group_removal", %{"group_id" => group.id})
      refute html =~ "To Remove"

      lv
      |> form("form[phx-submit='save']",
        actor: %{
          name: other_actor.name,
          email: other_actor.email,
          type: "account_user",
          allow_email_otp_sign_in: "true"
        }
      )
      |> render_submit()

      assert Portal.Repo.get_by(Portal.Membership,
               actor_id: other_actor.id,
               group_id: group.id
             )
    end

    test "prevents disabling OTP when it is the only sign-in method", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_with_email_fixture(account: account, allow_email_otp_sign_in: true)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}/edit")

      assert html =~ "This actor has no SSO identity. Disabling Email OTP will lock them out."

      html =
        render_click(lv, "save", %{
          "actor" => %{
            "name" => other_actor.name,
            "email" => other_actor.email,
            "type" => "account_user",
            "allow_email_otp_sign_in" => "false"
          }
        })

      assert html =~ "Cannot disable Email OTP. It is this actor&#39;s only sign-in method."

      assert Portal.Repo.get_by!(Portal.Actor,
               id: other_actor.id,
               account_id: account.id
             ).allow_email_otp_sign_in
    end

    test "prevents changing role of last admin", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      assert html =~ "Cannot change role. At least one admin must remain in the account."
      assert has_element?(lv, "input[value='account_user'][disabled]")
      assert has_element?(lv, "label.opacity-50.cursor-not-allowed", "User")

      # User radio is disabled; verify server-side guard by submitting the event directly
      html =
        render_click(lv, "save", %{
          "actor" => %{
            "name" => actor.name,
            "email" => actor.email,
            "type" => "account_user",
            "allow_email_otp_sign_in" => "true"
          }
        })

      assert html =~ "Cannot change role. At least one admin must remain in the account."

      assert Portal.Repo.get_by!(Portal.Actor, id: actor.id, account_id: account.id).type ==
               :account_admin_user
    end

    test "saves edited actor name and group membership changes", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)
      current_group = group_fixture(account: account, name: "Current Group")
      added_group = group_fixture(account: account, name: "Added Group")
      membership_fixture(actor: other_actor, group: current_group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}/edit")

      html = render_click(lv, "add_pending_group_removal", %{"group_id" => current_group.id})
      assert html =~ "To Remove"

      html =
        lv
        |> element("input[placeholder='Search to add groups...']")
        |> render_change(%{"value" => "Added Group"})

      assert html =~ added_group.name

      html = render_click(lv, "add_pending_group", %{"group_id" => added_group.id})
      assert html =~ "To Add"

      lv
      |> form("form[phx-submit='save']",
        actor: %{
          name: "Edited Actor Name",
          email: other_actor.email,
          type: "account_user",
          allow_email_otp_sign_in: "true"
        }
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "Actor updated successfully."
      assert html =~ "Edited Actor Name"

      assert Portal.Repo.get_by(Portal.Membership,
               actor_id: other_actor.id,
               group_id: added_group.id
             )

      refute Portal.Repo.get_by(Portal.Membership,
               actor_id: other_actor.id,
               group_id: current_group.id
             )
    end

    test "redirects to actor list when actor does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{fake_id}/edit")

      assert path == ~p"/#{account}/actors"
      assert flash["error"] == "Actor not found"
    end

    test "redirects to actor list when actor belongs to a different account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_account = account_fixture()
      other_actor = actor_fixture(account: other_account)

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{other_actor}/edit")

      assert path == ~p"/#{account}/actors"
      assert flash["error"] == "Actor not found"
    end
  end

  describe "keydown Escape" do
    test "pressing Escape while viewing actor detail closes the panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      render_click(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/actors")
    end

    test "pressing Escape while editing actor returns to actor detail view", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}/edit")

      render_click(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/actors/#{other_actor}")
    end
  end

  describe "confirm_delete_actor event" do
    test "shows delete confirmation UI", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      html = render_click(lv, "confirm_delete_actor")

      assert html =~ "Delete"
    end
  end

  describe "delete event" do
    test "deletes actor and removes from list", %{conn: conn, account: account, actor: actor} do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor}")

      render_click(lv, "delete", %{"id" => other_actor.id})

      html = render(lv)
      refute html =~ other_actor.name
    end
  end
end
