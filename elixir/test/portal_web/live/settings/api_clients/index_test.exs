defmodule PortalWeb.Settings.ApiClients.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures

  alias Portal.Actor

  setup do
    account = account_fixture(features: %{rest_api: true})
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  defp request_confirm(lv, action, actor_id) do
    lv
    |> element(
      "button[phx-click='request_confirm'][phx-value-action='#{action}'][phx-value-id='#{actor_id}']"
    )
    |> render_click()
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
    test "redirects to beta page when rest api is disabled", %{conn: conn} do
      account = account_fixture(features: %{rest_api: false})
      actor = admin_actor_fixture(account: account)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/settings/api_clients")

      assert to == ~p"/#{account}/settings/api_clients/beta"
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
          api_token: %{name: "Deploy Token", expires_at: expires_at}
        )
        |> render_submit()

      assert html =~ "Your API Token"
      assert html =~ "Store this token in a safe place."
      assert html =~ "code-api-token"

      render_click(lv, "close_reveal")
      assert_patch(lv, ~p"/#{account}/settings/api_clients")
      assert render(lv) =~ "Deploy Token"
    end

    test "shows billing limit error when account cannot create more api clients", %{conn: conn} do
      account =
        account_fixture(
          features: %{rest_api: true},
          limits: %{api_clients_count: 0}
        )

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
      refute is_nil(Repo.get_by!(Actor, account_id: account.id, id: api_client.id).disabled_at)

      request_confirm(lv, "toggle", api_client.id)
      html = render_click(lv, "enable", %{"id" => api_client.id})
      assert html =~ "Active"
      assert is_nil(Repo.get_by!(Actor, account_id: account.id, id: api_client.id).disabled_at)
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
