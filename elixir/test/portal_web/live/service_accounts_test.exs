defmodule PortalWeb.ServiceAccountsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/service_accounts"

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
    test "renders service accounts page title", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts")

      assert html =~ "Service Accounts"
    end

    test "lists service accounts by name", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts")

      assert html =~ service_account.name
    end

    test "does not list regular actors", %{conn: conn, account: account, actor: actor} do
      user = actor_fixture(account: account, type: :account_user)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts")

      refute html =~ user.name
    end

    test "shows empty state when no service accounts exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts")

      assert html =~ "No service accounts to display."
    end

    test "shows disabled badge for disabled service accounts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _disabled_service_account = disabled_actor_fixture(account: account, type: :service_account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts")

      assert html =~ "Disabled"
    end
  end

  describe ":new action" do
    test "New Service Account button patches to /service_accounts/new", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts")

      render_click(lv, "open_new_actor_panel")
      assert_patch(lv, ~p"/#{account}/service_accounts/new")
    end

    test "renders create form when navigating directly to /service_accounts/new", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

      assert html =~ "Create Service Account"
    end

    test "close_panel patches back to /service_accounts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/service_accounts")
    end
  end

  describe "create service account" do
    test "creates service account with token and shows created token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

      lv
      |> form("form[phx-submit='create_service_account']",
        actor: %{name: "CI Service Account"},
        token_expiration: expiration
      )
      |> render_submit()

      html = render(lv)
      service_account =
        Portal.Repo.get_by!(Portal.Actor,
          account_id: account.id,
          type: :service_account,
          name: "CI Service Account"
        )

      assert Portal.Repo.get_by(Portal.ClientToken, actor_id: service_account.id)
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
        |> live(~p"/#{account}/service_accounts/new")

      lv
      |> form("form[phx-submit='create_service_account']",
        actor: %{name: "Tokenless SA"},
        token_expiration: ""
      )
      |> render_submit()

      html = render(lv)
      service_account =
        Portal.Repo.get_by!(Portal.Actor,
          account_id: account.id,
          type: :service_account,
          name: "Tokenless SA"
        )

      refute Portal.Repo.get_by(Portal.ClientToken, actor_id: service_account.id)
      assert html =~ "Tokenless SA"
      refute html =~ "Token Created"
    end

    test "shows validation error when name exceeds 255 characters", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      invalid_name = String.duplicate("a", 256)
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

      html =
        lv
        |> form("form[phx-submit='create_service_account']",
          actor: %{name: invalid_name},
          token_expiration: expiration
        )
        |> render_submit()

      assert html =~ "should be at most 255 character(s)"
    end

    test "shows flash error when token expiration is unparsable", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

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

    test "does not create service account when billing limit is reached", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      account = update_account(account, %{limits: %{service_accounts_count: 0}})
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

      lv
      |> form("form[phx-submit='create_service_account']",
        actor: %{name: "Over Limit SA"},
        token_expiration: expiration
      )
      |> render_submit()

      refute Portal.Repo.get_by(Portal.Actor, name: "Over Limit SA", account_id: account.id)
    end

    test "applies pending group additions on create", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account, name: "Ops Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/new")

      html =
        lv
        |> element("input[placeholder='Search to add groups...']")
        |> render_change(%{"value" => group.name})

      assert html =~ group.name

      render_click(lv, "add_pending_group", %{"group_id" => group.id})

      lv
      |> form("form[phx-submit='create_service_account']",
        actor: %{name: "Grouped SA"},
        token_expiration: ""
      )
      |> render_submit()

      service_account =
        Portal.Repo.get_by!(Portal.Actor,
          account_id: account.id,
          type: :service_account,
          name: "Grouped SA"
        )

      assert Portal.Repo.get_by(Portal.Membership, actor_id: service_account.id, group_id: group.id)
    end
  end

  describe ":show action" do
    test "renders service account name in detail panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      assert html =~ service_account.name
    end

    test "redirects to service accounts list when ID not found", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/service_accounts/#{fake_id}")

      assert path == ~p"/#{account}/service_accounts"
      assert flash["error"] =~ "not found"
    end

    test "redirects when service account belongs to a different account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_account = account_fixture()
      other_service_account = service_account_fixture(account: other_account)

      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/service_accounts/#{other_service_account}")

      assert path == ~p"/#{account}/service_accounts"
    end

    test "change_tab event patches URL with tab param", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "change_tab", %{"tab" => "groups"})
      assert_patch(lv, ~p"/#{account}/service_accounts/#{service_account}?tab=groups")
    end

    test "shows existing tokens in the tokens tab", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      _token = client_token_fixture(account: account, actor: service_account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      assert html =~ "Token"
    end

    test "shows empty token state when no tokens", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      assert html =~ "No tokens."
    end
  end

  describe "token lifecycle" do
    test "open_add_token_form shows new token form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      html = render_click(lv, "open_add_token_form")
      assert html =~ "New Token"
    end

    test "cancel_add_token_form hides new token form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "open_add_token_form")
      html = render_click(lv, "cancel_add_token_form")
      refute html =~ "New Token"
    end

    test "create_token creates token and shows encoded token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "open_add_token_form")

      html =
        render_submit(element(lv, "form[phx-submit='create_token']"), %{
          "token_expiration" => expiration
        })

      assert html =~ "Token Created"
    end

    test "dismiss_created_token hides token value", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "open_add_token_form")

      render_submit(element(lv, "form[phx-submit='create_token']"), %{
        "token_expiration" => expiration
      })

      html = render_click(lv, "dismiss_created_token")
      refute html =~ "Token Created"
    end

    test "confirm and cancel delete token", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      html = render_click(lv, "confirm_delete_token", %{"id" => token.id})
      assert html =~ "Delete this token?"

      html = render_click(lv, "cancel_delete_token")
      refute html =~ "Delete this token?"
    end

    test "delete_token removes token from list", %{conn: conn, account: account, actor: actor} do
      service_account = service_account_fixture(account: account)
      token = client_token_fixture(account: account, actor: service_account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "confirm_delete_token", %{"id" => token.id})
      render_click(lv, "delete_token", %{"id" => token.id})

      html = render(lv)
      refute Portal.Repo.get_by(Portal.ClientToken, id: token.id)
      assert html =~ "No tokens."
    end
  end

  describe "disable / enable / delete" do
    test "confirm and cancel disable service account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      html = render_click(lv, "confirm_disable_actor")
      assert html =~ "Disable"

      html = render_click(lv, "cancel_disable_actor")
      refute html =~ "Service account disabled successfully"
      refute Portal.Repo.get_by!(Portal.Actor, id: service_account.id, account_id: account.id).disabled_at
    end

    test "disable sets disabled_at and shows success flash", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "confirm_disable_actor")
      render_click(lv, "disable", %{"id" => service_account.id})

      assert Portal.Repo.get_by!(Portal.Actor, id: service_account.id, account_id: account.id).disabled_at
    end

    test "enable clears disabled_at and shows success flash", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = disabled_actor_fixture(account: account, type: :service_account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "enable", %{"id" => service_account.id})

      refute Portal.Repo.get_by!(Portal.Actor, id: service_account.id, account_id: account.id).disabled_at
    end

    test "confirm and cancel delete service account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      html = render_click(lv, "confirm_delete_actor")
      assert html =~ "Delete"

      html = render_click(lv, "cancel_delete_actor")
      refute html =~ "Service account deleted successfully"
      assert html =~ service_account.name
      assert Portal.Repo.get_by(Portal.Actor, id: service_account.id, account_id: account.id)
    end

    test "delete removes service account and patches back to list", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}")

      render_click(lv, "confirm_delete_actor")
      render_click(lv, "delete", %{"id" => service_account.id})

      assert_patch(lv, ~p"/#{account}/service_accounts")
      refute Portal.Repo.get_by(Portal.Actor, id: service_account.id, account_id: account.id)
    end
  end

  describe ":edit action" do
    test "renders edit form pre-populated with service account name", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      assert html =~ "Save Changes"
      assert html =~ service_account.name
    end

    test "cancel_actor_edit_form patches back to show panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      render_click(lv, "cancel_actor_edit_form")
      assert_patch(lv, ~p"/#{account}/service_accounts/#{service_account}")
    end

    test "save with valid name updates service account and shows success flash", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      html =
        lv
        |> form("form[phx-submit='save']", actor: %{name: "Updated SA Name"})
        |> render_submit()

      updated_service_account =
        Portal.Repo.get_by!(Portal.Actor, id: service_account.id, account_id: account.id)

      assert updated_service_account.name == "Updated SA Name"
      assert html =~ "Updated SA Name"
      assert html =~ "updated successfully"
    end

    test "save with invalid name shows validation error", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      invalid_name = String.duplicate("a", 256)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      html =
        lv
        |> form("form[phx-submit='save']", actor: %{name: invalid_name})
        |> render_submit()

      assert html =~ "should be at most 255 character(s)"
    end

    test "searches groups and adds pending group addition", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "Ops Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      html =
        lv
        |> element("input[placeholder='Search to add groups...']")
        |> render_change(%{"value" => group.name})

      assert html =~ group.name

      html = render_click(lv, "add_pending_group", %{"group_id" => group.id})
      assert html =~ "To Add"
    end

    test "remove_pending_group_addition removes pending add", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "Ops Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      lv
      |> element("input[placeholder='Search to add groups...']")
      |> render_change(%{"value" => group.name})

      render_click(lv, "add_pending_group", %{"group_id" => group.id})
      html = render_click(lv, "remove_pending_group_addition", %{"group_id" => group.id})
      refute html =~ group.name

      refute has_element?(
               lv,
               "button[phx-click='remove_pending_group_addition'][phx-value-group_id='#{group.id}']"
             )
    end

    test "add_pending_group_removal and undo_pending_group_removal toggle group_id in state", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "Existing Group")
      membership_fixture(actor: service_account, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      render_click(lv, "add_pending_group_removal", %{"group_id" => group.id})
      render_click(lv, "undo_pending_group_removal", %{"group_id" => group.id})

      # The membership should still exist after undoing
      assert Portal.Repo.get_by(Portal.Membership, actor_id: service_account.id, group_id: group.id)
    end

    test "saving with pending group additions creates memberships in DB", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "New Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      lv
      |> element("input[placeholder='Search to add groups...']")
      |> render_change(%{"value" => group.name})

      render_click(lv, "add_pending_group", %{"group_id" => group.id})

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      assert Portal.Repo.get_by(Portal.Membership, actor_id: service_account.id, group_id: group.id)
    end

    test "saving with pending group removals deletes memberships from DB", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "Existing Group")
      membership_fixture(actor: service_account, group: group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      render_click(lv, "add_pending_group_removal", %{"group_id" => group.id})

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      refute Portal.Repo.get_by(Portal.Membership, actor_id: service_account.id, group_id: group.id)
    end

    test "shows current groups for a service account in the current column", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      current_group = group_fixture(account: account, name: "Current Group")
      membership_fixture(actor: service_account, group: current_group)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      assert render(lv) =~ current_group.name

      assert has_element?(
               lv,
               "button[phx-click='add_pending_group_removal'][phx-value-group_id='#{current_group.id}']"
             )
    end

    test "saving with pending group additions shows the group in the groups tab", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "Visible Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      lv
      |> element("input[placeholder='Search to add groups...']")
      |> render_change(%{"value" => group.name})

      render_click(lv, "add_pending_group", %{"group_id" => group.id})

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      render_click(lv, "change_tab", %{"tab" => "groups"})
      assert render(lv) =~ group.name
    end

    test "shows error flash when adding a group membership to a service account fails", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      service_account = service_account_fixture(account: account)
      group = group_fixture(account: account, name: "Target Group")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/service_accounts/#{service_account}/edit")

      lv
      |> element("input[placeholder='Search to add groups...']")
      |> render_change(%{"value" => group.name})

      render_click(lv, "add_pending_group", %{"group_id" => group.id})

      membership_fixture(actor: service_account, group: group)

      lv
      |> form("form[phx-submit='save']", actor: %{name: service_account.name})
      |> render_submit()

      assert render(lv) =~ "Failed to update some group memberships."
    end
  end
end
