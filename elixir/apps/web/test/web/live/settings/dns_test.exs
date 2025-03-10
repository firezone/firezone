defmodule Web.Live.Settings.DNSTest do
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

  test "renders form with no input fields", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{config: %{clients_upstream_dns: []}})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    form = lv |> form("form")

    assert find_inputs(form) == [
             "account[config][_persistent_id]",
             "account[config][clients_upstream_dns_drop][]",
             "account[config][search_domain]"
           ]
  end

  test "renders input field on button click", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{config: %{clients_upstream_dns: []}})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    attrs = %{
      "_target" => ["account", "config", "clients_upstream_dns_sort"],
      "account" => %{
        "config" => %{
          "_persistent_id" => "0",
          "clients_upstream_dns_drop" => [""],
          "clients_upstream_dns_sort" => ["new"]
        }
      }
    }

    lv
    |> render_click(:change, attrs)

    form = lv |> form("form")

    assert find_inputs(form) == [
             "account[config][_persistent_id]",
             "account[config][clients_upstream_dns][0][_persistent_id]",
             "account[config][clients_upstream_dns][0][address]",
             "account[config][clients_upstream_dns][0][protocol]",
             "account[config][clients_upstream_dns_drop][]",
             "account[config][clients_upstream_dns_sort][]",
             "account[config][search_domain]"
           ]
  end

  test "saves search domain", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account = Fixtures.Accounts.update_account(account, %{config: %{clients_upstream_dns: []}})

    attrs = %{
      account: %{
        config: %{
          search_domain: "example.com"
        }
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
             "account[config][_persistent_id]",
             "account[config][clients_upstream_dns_drop][]",
             "account[config][search_domain]"
           ]

    account = Domain.Accounts.fetch_account_by_id!(account.id)

    assert account.config.search_domain == "example.com"
  end

  test "renders error for invalid search domain", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account = Fixtures.Accounts.update_account(account, %{config: %{clients_upstream_dns: []}})

    attrs = %{
      account: %{
        config: %{
          search_domain: "example"
        }
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form", attrs)
           |> render_change() =~ "must be a valid fully-qualified domain name"
  end

  test "saves custom DNS server address", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{config: %{clients_upstream_dns: []}})

    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{"0" => %{address: "8.8.8.8"}}
        }
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> element("form")
    |> render_change(%{
      "account" => %{
        "config" => %{
          "clients_upstream_dns_drop" => [""],
          "clients_upstream_dns_sort" => ["new"]
        }
      }
    })

    lv
    |> form("form", attrs)
    |> render_submit()

    assert lv
           |> form("form")
           |> find_inputs() == [
             "account[config][_persistent_id]",
             "account[config][clients_upstream_dns][0][_persistent_id]",
             "account[config][clients_upstream_dns][0][address]",
             "account[config][clients_upstream_dns][0][protocol]",
             "account[config][clients_upstream_dns_drop][]",
             "account[config][clients_upstream_dns_sort][]",
             "account[config][search_domain]"
           ]
  end

  test "removes blank entries upon save", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            "0" => %{address: ""}
          }
        }
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
             "account[config][_persistent_id]",
             "account[config][clients_upstream_dns][0][_persistent_id]",
             "account[config][clients_upstream_dns][0][address]",
             "account[config][clients_upstream_dns][0][protocol]",
             "account[config][clients_upstream_dns][1][_persistent_id]",
             "account[config][clients_upstream_dns][1][address]",
             "account[config][clients_upstream_dns][1][protocol]",
             "account[config][clients_upstream_dns][2][_persistent_id]",
             "account[config][clients_upstream_dns][2][address]",
             "account[config][clients_upstream_dns][2][protocol]",
             "account[config][clients_upstream_dns_drop][]",
             "account[config][clients_upstream_dns_sort][]",
             "account[config][search_domain]"
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
      account: %{
        config: %{
          clients_upstream_dns: %{"0" => addr1}
        }
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
           |> form("form", %{
             account: %{
               config: %{clients_upstream_dns: %{"1" => addr1}}
             }
           })
           |> render_change() =~ "all addresses must be unique"

    refute lv
           |> form("form", %{
             account: %{
               config: %{clients_upstream_dns: %{"1" => addr2}}
             }
           })
           |> render_change() =~ "all addresses must be unique"

    assert lv
           |> form("form", %{
             account: %{
               config: %{clients_upstream_dns: %{"1" => addr1_dup}}
             }
           })
           |> render_change() =~ "all addresses must be unique"
  end

  test "displays 'cannot be empty' error message", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{"0" => %{address: "8.8.8.8"}}
        }
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
           |> form("form", %{
             account: %{
               config: %{
                 clients_upstream_dns: %{"0" => %{address: ""}}
               }
             }
           })
           |> render_change() =~ "can&#39;t be blank"
  end
end
