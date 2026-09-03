defmodule PortalWeb.Settings.ApiClients.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  alias Portal.Actor

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  defp request_confirm(lv, action, actor_id) do
    lv
    |> element("button[phx-click='toggle_actor_actions'][phx-value-id='#{actor_id}']")
    |> render_click()

    lv
    |> element(
      "button[phx-click='request_confirm'][phx-value-action='#{action}'][phx-value-id='#{actor_id}']"
    )
    |> render_click()
  end

  defp open_actor_actions(lv, actor_id) do
    lv
    |> element("button[phx-click='toggle_actor_actions'][phx-value-id='#{actor_id}']")
    |> render_click()
  end

  defp has_actor_action_button?(html, action, actor_id) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(
      "button[phx-click='request_confirm'][phx-value-action='#{action}'][phx-value-id='#{actor_id}']"
    )
    |> Enum.any?()
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/api_clients"

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
    test "does not join tokens from another account when actor IDs match", %{
      account: account,
      actor: admin_actor
    } do
      shared_id = Ecto.UUID.generate()

      Repo.insert!(%Actor{
        id: shared_id,
        account_id: account.id,
        type: :api_client,
        name: "Local API Client"
      })

      other_account = account_fixture()

      other_actor =
        Repo.insert!(%Actor{
          id: shared_id,
          account_id: other_account.id,
          type: :api_client,
          name: "Other API Client"
        })

      _other_token = api_token_fixture(account: other_account, actor: other_actor)
      subject = subject_fixture(account: account, actor: admin_actor)

      assert [
               {%Actor{
                  id: ^shared_id,
                  account_id: account_id,
                  name: "Local API Client"
                }, nil}
             ] =
               PortalWeb.Settings.ApiClients.Index.Database.list_actors_with_token(subject)

      assert account_id == account.id
    end

    test "renders empty state when no tokens", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      assert html =~ "API Tokens"
      assert html =~ "No API tokens yet"
      assert html =~ "Add an API token"
    end

    test "renders token rows with activity details", %{conn: conn, account: account, actor: actor} do
      active_client = api_client_fixture(account: account, name: "Terraform Token")

      disabled_client =
        disabled_actor_fixture(account: account, type: :api_client, name: "CI Token")

      api_token_fixture(
        account: account,
        actor: active_client,
        expires_at: ~U[2030-01-01 00:00:00.000000Z],
        last_seen_at: ~U[2029-01-01 00:00:00.000000Z],
        last_seen_remote_ip: {203, 0, 113, 10}
      )

      api_token_fixture(
        account: account,
        actor: disabled_client,
        expires_at: ~U[2030-02-01 00:00:00.000000Z]
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      assert html =~ "Terraform Token"
      assert html =~ "CI Token"
      assert html =~ "Active"
      assert html =~ "Disabled"
      assert html =~ "203.0.113.10"
    end
  end

  describe ":new action" do
    test "renders create token panel and closes it", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      assert html =~ "New API Token"
      assert html =~ "Create Token"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/api_clients")
    end

    test "closes creation panel on escape", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/api_clients")
    end

    test "validates required fields", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      html =
        lv
        |> form("#api-token-new-form", api_token: %{name: "", expires_at: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "creates token on submit, reveals value, and closes reveal", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      expires_at = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      html =
        lv
        |> form("#api-token-new-form",
          api_token: %{
            name: "Deploy Token",
            expires_at: expires_at,
            scopes: ["policies:read"]
          }
        )
        |> render_submit()

      assert html =~ "Your API Token"
      assert html =~ "Store this token in a safe place."
      assert html =~ "code-api-token"

      render_click(lv, "close_reveal")
      assert_patch(lv, ~p"/#{account}/settings/api_clients")
      assert render(lv) =~ "Deploy Token"
    end

    test "stores the scopes that were ticked", %{conn: conn, account: account, actor: actor} do
      expires_at = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      lv
      |> form("#api-token-new-form",
        api_token: %{
          name: "Limited",
          expires_at: expires_at,
          scopes: ["policies:read", "resources:write"]
        }
      )
      |> render_submit()

      token = Portal.Repo.get_by!(Portal.APIToken, account_id: account.id)

      # resources:write brings its read along, since the locked box never submits.
      assert Enum.sort(token.scopes) == ["policies:read", "resources:read", "resources:write"]
    end

    test "refuses to create a token with nothing ticked", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      expires_at = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      html =
        lv
        |> form("#api-token-new-form", api_token: %{name: "Empty", expires_at: expires_at})
        |> render_submit()

      assert html =~ "Select at least one permission"
      assert html =~ "border-error"
      assert Portal.Repo.get_by(Portal.APIToken, account_id: account.id) == nil
    end

    test "the preset buttons tick the right boxes", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/new")

      html = render_click(lv, "select_scopes", %{"preset" => "all"})
      assert html =~ ~s(value="policies:write" checked)

      # read-only leaves every write box clear
      html = render_click(lv, "select_scopes", %{"preset" => "read"})
      assert html =~ ~s(value="policies:read" checked)
      refute html =~ ~s(value="policies:write" checked)

      html = render_click(lv, "select_scopes", %{"preset" => "none"})
      refute html =~ ~s(value="policies:read" checked)

      # anything unrecognised selects nothing rather than widening the grant
      html = render_click(lv, "select_scopes", %{"preset" => "everything"})
      refute html =~ "checked"
    end

    test "changes the scopes of an existing token", %{conn: conn, account: account, actor: actor} do
      other = actor_fixture(type: :api_client, account: account)

      token =
        api_token_fixture(actor: other, account: account, scopes: ["policies:read"])

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/#{other}/edit")

      assert html =~ ~s(value="policies:read" checked)

      lv
      |> form("#api-token-edit-form",
        actor: %{name: other.name},
        api_token: %{scopes: ["sites:write"]}
      )
      |> render_submit()

      reloaded = Portal.Repo.get_by!(Portal.APIToken, account_id: account.id, id: token.id)
      assert Enum.sort(reloaded.scopes) == ["sites:read", "sites:write"]
    end

    test "changes the scopes of every token belonging to the actor", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      api_client = actor_fixture(type: :api_client, account: account)
      first = api_token_fixture(actor: api_client, account: account, scopes: ["policies:read"])
      second = api_token_fixture(actor: api_client, account: account, scopes: ["resources:read"])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

      lv
      |> form("#api-token-edit-form",
        actor: %{name: api_client.name},
        api_token: %{scopes: ["sites:write"]}
      )
      |> render_submit()

      for token <- [first, second] do
        reloaded = Portal.Repo.get_by!(Portal.APIToken, account_id: account.id, id: token.id)
        assert Enum.sort(reloaded.scopes) == ["sites:read", "sites:write"]
      end
    end

    test "does not change token scopes when the actor update is invalid", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      api_client = actor_fixture(type: :api_client, account: account, name: "Original")
      token = api_token_fixture(actor: api_client, account: account, scopes: ["policies:read"])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients/#{api_client}/edit")

      html =
        lv
        |> form("#api-token-edit-form",
          actor: %{name: ""},
          api_token: %{scopes: ["sites:write"]}
        )
      |> render_submit()

      assert html =~ "can&#39;t be blank"

      assert Portal.Repo.get_by!(Portal.APIToken, account_id: account.id, id: token.id).scopes == [
               "policies:read"
             ]

      assert Portal.Repo.get_by!(Portal.Actor, account_id: account.id, id: api_client.id).name ==
               "Original"
    end

    test "shows billing limit error when account cannot create more api clients", %{conn: conn} do
      account = account_fixture(limits: %{api_clients_count: 0})

      actor = admin_actor_fixture(account: account)

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => message}}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/settings/api_clients/new")

      assert to == ~p"/#{account}/settings/api_clients"

      assert message ==
               "You have reached the maximum number of API tokens allowed for your account."
    end
  end

  describe ":edit action and row actions" do
    test "edits an api token actor name and closes on escape", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      api_client = api_client_fixture(account: account, name: "Old Name")
      api_token_fixture(account: account, actor: api_client)
      conn = authorize_conn(conn, actor)

      {:ok, lv, html} =
        live(conn, ~p"/#{account}/settings/api_clients/#{api_client}/edit")

      assert html =~ "Edit API Token"

      html =
        lv
        |> form("#api-token-edit-form", actor: %{name: "Updated Name"})
        |> render_submit()

      assert_patch(lv, ~p"/#{account}/settings/api_clients")
      assert html =~ "Updated Name"

      assert %Actor{name: "Updated Name"} =
               Repo.get_by!(Actor, account_id: account.id, id: api_client.id)

      {:ok, lv, _html} =
        live(conn, ~p"/#{account}/settings/api_clients/#{api_client}/edit")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/api_clients")
    end

    test "closes the actions menu when navigating to edit", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      api_client = api_client_fixture(account: account, name: "Edit From Menu")
      api_token_fixture(account: account, actor: api_client)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      html = open_actor_actions(lv, api_client.id)
      assert has_actor_action_button?(html, "toggle", api_client.id)

      lv
      |> element("a[href='/" <> "#{account.slug}/settings/api_clients/#{api_client.id}/edit']")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/settings/api_clients/#{api_client}/edit")

      html = render(lv)
      assert html =~ "Edit API Token"
      refute has_actor_action_button?(html, "toggle", api_client.id)
    end

    test "opens and cancels disable confirmation", %{conn: conn, account: account, actor: actor} do
      api_client = api_client_fixture(account: account, name: "Toggle Client")
      api_token_fixture(account: account, actor: api_client)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      html = request_confirm(lv, "toggle", api_client.id)
      assert html =~ "Disable this API Token?"

      html = render_click(lv, "cancel_confirm")
      refute html =~ "Disable this API Token?"
    end

    test "disables and re-enables an api client", %{conn: conn, account: account, actor: actor} do
      api_client = api_client_fixture(account: account, name: "Toggle Client")
      api_token_fixture(account: account, actor: api_client)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      request_confirm(lv, "toggle", api_client.id)
      html = render_click(lv, "disable", %{"id" => api_client.id})
      assert html =~ "Disabled"
      assert Repo.get_by!(Actor, account_id: account.id, id: api_client.id).is_disabled

      request_confirm(lv, "toggle", api_client.id)
      html = render_click(lv, "enable", %{"id" => api_client.id})
      assert html =~ "Active"
      refute Repo.get_by!(Actor, account_id: account.id, id: api_client.id).is_disabled
    end

    test "does not re-enable an API client when the billing limit is reached", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      account = update_account(account, %{limits: %{api_clients_count: 0}})
      api_client = disabled_actor_fixture(account: account, type: :api_client)
      api_token_fixture(account: account, actor: api_client)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      request_confirm(lv, "toggle", api_client.id)
      html = render_click(lv, "enable", %{"id" => api_client.id})

      assert html =~ "maximum number of API tokens allowed for your account"
      assert Repo.get_by!(Actor, account_id: account.id, id: api_client.id).is_disabled
    end

    test "deletes an api client after confirmation", %{conn: conn, account: account, actor: actor} do
      api_client = api_client_fixture(account: account, name: "Delete Client")
      api_token_fixture(account: account, actor: api_client)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/api_clients")

      html = request_confirm(lv, "delete", api_client.id)
      assert html =~ "Delete this API Token?"

      html = render_click(lv, "delete", %{"id" => api_client.id})
      refute html =~ "Delete Client"
      refute Repo.get_by(Actor, account_id: account.id, id: api_client.id)
    end
  end
end
