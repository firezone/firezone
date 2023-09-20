defmodule Web.Live.Settings.DNS.IndexTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    assert live(conn, ~p"/#{account}/settings/dns") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "DNS Settings"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    form = lv |> form("form")

    assert find_inputs(form) == [
             "clients_upstream_dns",
             "resolver"
           ]
  end

  test "saves custom DNS server address", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      "resolver" => "custom",
      "clients_upstream_dns" => "8.8.8.8"
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", %{"resolver" => "custom"})
    |> render_change()

    assert lv
           |> form("form", attrs)
           |> render_submit() =~ "DNS settings have been updated!"
  end

  test "removes duplicate DNS addresses upon save", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      "resolver" => "custom",
      "clients_upstream_dns" => "8.8.8.8, 8.8.8.8"
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", %{"resolver" => "custom"})
    |> render_change()

    lv
    |> form("form", attrs)
    |> render_submit()

    assert lv
           |> element("input[name='clients_upstream_dns']")
           |> render() =~ "value=\"8.8.8.8\""
  end

  test "disables address field when system resolver selected", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      "resolver" => "custom",
      "clients_upstream_dns" => "8.8.8.8"
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", %{"resolver" => "custom"})
    |> render_change()

    assert lv
           |> form("form", attrs)
           |> render_change() =~ "8.8.8.8"

    lv |> form("form", %{"resolver" => "system"}) |> render_change()

    assert lv
           |> element("input[name='clients_upstream_dns']")
           |> render() =~ "disabled"
  end
end
