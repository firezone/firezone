defmodule Web.Live.Settings.DNS.IndexTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/dns"

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
             "configuration[clients_upstream_dns][0][address]",
             "configuration[clients_upstream_dns][0][protocol]"
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
             "configuration[clients_upstream_dns][0][protocol]",
             "configuration[clients_upstream_dns][1][_persistent_id]",
             "configuration[clients_upstream_dns][1][address]",
             "configuration[clients_upstream_dns][1][protocol]"
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
             "configuration[clients_upstream_dns][0][protocol]",
             "configuration[clients_upstream_dns][1][_persistent_id]",
             "configuration[clients_upstream_dns][1][address]",
             "configuration[clients_upstream_dns][1][protocol]"
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
             "configuration[clients_upstream_dns][0][address]",
             "configuration[clients_upstream_dns][0][protocol]"
           ]
  end

  test "warns when duplicate IPv4 addresses found", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    addr1 = %{address: "8.8.8.8"}
    addr1_dup = %{address: "8.8.8.8:53"}
    addr2 = %{address: "1.1.1.1"}

    attrs = %{
      configuration: %{
        clients_upstream_dns: %{"0" => addr1}
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
           |> form("form", %{configuration: %{clients_upstream_dns: %{"1" => addr1}}})
           |> render_change() =~ "no duplicates allowed"

    refute lv
           |> form("form", %{configuration: %{clients_upstream_dns: %{"1" => addr2}}})
           |> render_change() =~ "no duplicates allowed"

    assert lv
           |> form("form", %{configuration: %{clients_upstream_dns: %{"1" => addr1_dup}}})
           |> render_change() =~ "no duplicates allowed"
  end

  test "does not display 'cannot be empty' error message", %{
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

    refute lv
           |> form("form", %{configuration: %{clients_upstream_dns: %{"0" => %{address: ""}}}})
           |> render_change() =~ "can&#39;t be blank"
  end
end
