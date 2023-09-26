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
             "configuration[clients_upstream_dns][0][_persistent_id]",
             "configuration[clients_upstream_dns][0][address]"
           ]
  end

  test "saves custom DNS server address", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{configuration: %{clients_upstream_dns: %{"0" => %{address: "8.8.8.8"}}}}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", attrs)
    |> render_submit()

    assert lv
           |> form("form")
           |> find_inputs() == [
             "configuration[clients_upstream_dns][0][_persistent_id]",
             "configuration[clients_upstream_dns][0][address]",
             "configuration[clients_upstream_dns][1][_persistent_id]",
             "configuration[clients_upstream_dns][1][address]"
           ]
  end

  test "removes blank entries upon save", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      configuration: %{
        clients_upstream_dns: %{"0" => %{address: "8.8.8.8"}}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", attrs)
    |> render_submit()

    assert lv
           |> form("form")
           |> find_inputs() == [
             "configuration[clients_upstream_dns][0][_persistent_id]",
             "configuration[clients_upstream_dns][0][address]",
             "configuration[clients_upstream_dns][1][_persistent_id]",
             "configuration[clients_upstream_dns][1][address]"
           ]

    empty_attrs = %{
      configuration: %{
        clients_upstream_dns: %{"0" => %{address: ""}}
      }
    }

    lv |> form("form", empty_attrs) |> render_submit()

    assert lv
           |> form("form")
           |> find_inputs() == [
             "configuration[clients_upstream_dns][0][_persistent_id]",
             "configuration[clients_upstream_dns][0][address]"
           ]
  end

  test "warns when duplicates found", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    addr = %{address: "8.8.8.8"}

    attrs = %{
      configuration: %{
        clients_upstream_dns: %{"0" => addr}
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", attrs)
    |> render_submit()

    assert lv
           |> form("form", %{configuration: %{clients_upstream_dns: %{"1" => addr}}})
           |> render_change() =~ "should not contain duplicates"
  end
end
