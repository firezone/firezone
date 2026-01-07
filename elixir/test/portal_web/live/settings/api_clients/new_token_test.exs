defmodule PortalWeb.Live.Settings.ApiClients.NewTokenTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    api_client = api_client_fixture(account: account)

    %{
      account: account,
      actor: actor,
      api_client: api_client
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    api_client: api_client,
    conn: conn
  } do
    path = ~p"/#{account}/settings/api_clients/#{api_client}/new_token"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "redirects to API client page when token limit is reached", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    account = update_account(account, %{limits: %{api_tokens_per_client_count: 1}})
    _token = api_token_fixture(account: account, actor: api_client)

    assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
             conn
             |> authorize_conn(actor)
             |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    assert path == ~p"/#{account}/settings/api_clients/#{api_client}"
    assert flash["error"] =~ "maximum number of API tokens"
  end

  test "renders breadcrumbs item", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ api_client.name
    assert breadcrumbs =~ "Add Token"
  end

  test "renders form", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    assert lv
           |> form("form[phx-submit=submit]")
           |> find_inputs() == [
             "api_token[expires_at]",
             "api_token[name]"
           ]
  end

  test "renders changeset errors on submit", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    attrs = %{expires_at: "1991-01-01"}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    html =
      lv
      |> form("form[phx-submit=submit]", api_token: attrs)
      |> render_submit()

    assert %{
             "api_token[expires_at]" => ["must be greater than" <> _]
           } = form_validation_errors(html)
  end

  test "creates a new token on valid attrs", %{
    account: account,
    api_client: api_client,
    actor: actor,
    conn: conn
  } do
    expires_at = Date.utc_today() |> Date.add(3)

    attrs = %{
      name: "Test Token",
      expires_at: Date.to_iso8601(expires_at)
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    html =
      lv
      |> form("form[phx-submit=submit]", api_token: attrs)
      |> render_submit()

    assert html =~ "Your API Token"
    assert html =~ "Store this in a safe place."
    assert html =~ "It won&#39;t be shown again."

    assert html
           |> Floki.parse_fragment!()
           |> Floki.find("code")
           |> element_to_text()
           |> String.trim()
           |> String.first() == "."

    lv
    |> element("a", "Back to API Client")
    |> render_click()

    {path, _flash} = assert_redirect(lv)

    assert path =~ ~p"/#{account}/settings/api_clients/#{api_client}"
  end

  test "redirects when limit is reached during submit", %{
    account: account,
    actor: actor,
    api_client: api_client,
    conn: conn
  } do
    account = update_account(account, %{limits: %{api_tokens_per_client_count: 1}})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    # Create a token after loading the page to simulate a race condition
    _token = api_token_fixture(account: account, actor: api_client)

    expires_at = Date.utc_today() |> Date.add(3)

    lv
    |> form("form[phx-submit=submit]",
      api_token: %{name: "Test", expires_at: Date.to_iso8601(expires_at)}
    )
    |> render_submit()

    assert_redirect(lv, ~p"/#{account}/settings/api_clients/#{api_client}")
  end
end
