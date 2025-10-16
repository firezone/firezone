defmodule Web.Live.Settings.ApiClient.NewTokenTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    api_client = Fixtures.Actors.create_actor(type: :api_client, account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
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
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    assert lv
           |> form("form")
           |> find_inputs() == [
             "token[expires_at]",
             "token[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    lv
    |> form("form", identity: %{})
    |> validate_change(
      %{token: %{expires_at: "1991-01-01"}},
      fn form, _html ->
        assert %{
                 "token[expires_at]" => ["must be greater than" <> _]
               } = form_validation_errors(form)
      end
    )
  end

  test "renders changeset errors on submit", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    attrs = %{expires_at: "1991-01-01"}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    html =
      lv
      |> form("form", token: attrs)
      |> render_submit()

    assert %{
             "token[expires_at]" => ["must be greater than" <> _]
           } = form_validation_errors(html)
  end

  test "creates a new token on valid attrs", %{
    account: account,
    api_client: api_client,
    identity: identity,
    conn: conn
  } do
    expires_at = Date.utc_today() |> Date.add(3)

    attrs = %{
      name: Fixtures.Actors.actor_attrs().name,
      expires_at: Date.to_iso8601(expires_at)
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/api_clients/#{api_client}/new_token")

    html =
      lv
      |> form("form", token: attrs)
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
end
