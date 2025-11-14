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

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "DNS Settings"
  end

  test "renders form with resolver type dropdown", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{config: %{upstream_do53: []}})

    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "Resolver Type"
    assert html =~ "System Default Resolvers"
    assert html =~ "Google Public DNS"
    assert html =~ "Cloudflare DNS"
    assert html =~ "Quad9 DNS"
    assert html =~ "OpenDNS"
    assert html =~ "Custom DNS Servers"
  end

  test "shows custom DNS fields when custom resolver type selected", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{config: %{upstream_do53: []}})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Change to custom_do53
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "custom_do53"})

    # Now add a resolver
    attrs = %{
      "_target" => ["account", "config", "upstream_do53_sort"],
      "account" => %{
        "config" => %{
          "_persistent_id" => "0",
          "upstream_do53_drop" => [""],
          "upstream_do53_sort" => ["new"]
        }
      }
    }

    html = lv |> render_click(:change, attrs)

    assert html =~ "IP Address"
  end

  test "saves search domain", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account = Fixtures.Accounts.update_account(account, %{config: %{upstream_do53: []}})

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
             "account[config][upstream_do53_drop][]",
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
    account = Fixtures.Accounts.update_account(account, %{config: %{upstream_do53: []}})

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
    Fixtures.Accounts.update_account(account, %{config: %{upstream_do53: []}})

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Select custom resolver type
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "custom_do53"})

    attrs = %{
      account: %{
        config: %{
          upstream_do53: %{"0" => %{"address" => "8.8.8.8"}},
          upstream_doh_provider: ""
        }
      }
    }

    lv
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Accounts.fetch_account_by_id!(account.id)
    assert length(account.config.upstream_do53) == 1
    assert hd(account.config.upstream_do53).address == "8.8.8.8"
  end

  test "removes blank entries upon save", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Select custom resolver type
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "custom_do53"})

    attrs = %{
      account: %{
        config: %{
          upstream_do53: %{"0" => %{"address" => ""}},
          upstream_doh_provider: ""
        }
      }
    }

    lv
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Accounts.fetch_account_by_id!(account.id)
    assert Enum.empty?(account.config.upstream_do53)
  end

  test "warns when duplicate IPv4 addresses found", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Select custom resolver type
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "custom_do53"})

    assert lv
           |> form("form", %{
             account: %{
               config: %{
                 upstream_do53: %{
                   "0" => %{"address" => "8.8.8.8"},
                   "1" => %{"address" => "8.8.8.8"}
                 },
                 upstream_doh_provider: ""
               }
             }
           })
           |> render_change() =~ "all addresses must be unique"

    refute lv
           |> form("form", %{
             account: %{
               config: %{
                 upstream_do53: %{
                   "0" => %{"address" => "8.8.8.8"},
                   "1" => %{"address" => "1.1.1.1"}
                 },
                 upstream_doh_provider: ""
               }
             }
           })
           |> render_change() =~ "all addresses must be unique"
  end

  test "validates IP addresses", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Select custom resolver type
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "custom_do53"})

    assert lv
           |> form("form", %{
             account: %{
               config: %{
                 upstream_do53: %{"0" => %{"address" => "invalid"}},
                 upstream_doh_provider: ""
               }
             }
           })
           |> render_change() =~ "must be a valid IP address"

    refute lv
           |> form("form", %{
             account: %{
               config: %{
                 upstream_do53: %{"0" => %{"address" => "8.8.8.8"}},
                 upstream_doh_provider: ""
               }
             }
           })
           |> render_change() =~ "must be a valid IP address"
  end

  test "saves DoH provider selection", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Select Google DoH
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "google"})

    lv
    |> form("form")
    |> render_submit()

    account = Domain.Accounts.fetch_account_by_id!(account.id)
    assert account.config.upstream_doh_provider == :google
    assert Enum.empty?(account.config.upstream_do53)
  end

  test "saves system resolver selection", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with DoH provider set
    Fixtures.Accounts.update_account(account, %{
      config: %{upstream_doh_provider: :cloudflare}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Select system default
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "system"})

    lv
    |> form("form")
    |> render_submit()

    account = Domain.Accounts.fetch_account_by_id!(account.id)
    assert account.config.upstream_doh_provider == nil
    assert Enum.empty?(account.config.upstream_do53)
  end

  test "prevents setting both DoH and Do53", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Try to submit both (this shouldn't be possible via UI but test the validation)
    html =
      lv
      |> form("form", %{
        account: %{
          config: %{
            upstream_do53: %{"0" => %{"address" => "8.8.8.8"}},
            upstream_doh_provider: "google"
          }
        }
      })
      |> render_change()

    assert html =~ "cannot be used with"
  end

  test "clears custom Do53 servers when switching to DoH", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with custom Do53 servers configured
    Fixtures.Accounts.update_account(account, %{
      config: %{
        upstream_do53: [
          %{address: "8.8.8.8"},
          %{address: "1.1.1.1"}
        ]
      }
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Switch to Google DoH
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "google"})

    lv
    |> form("form")
    |> render_submit()

    # Verify Do53 servers are cleared and DoH is set
    account = Domain.Accounts.fetch_account_by_id!(account.id)
    assert account.config.upstream_doh_provider == :google
    assert Enum.empty?(account.config.upstream_do53)
  end

  test "clears DoH provider when switching to custom Do53", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with DoH provider configured
    Fixtures.Accounts.update_account(account, %{
      config: %{upstream_doh_provider: :cloudflare}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Switch to custom Do53
    lv
    |> element("select[name='resolver_type']")
    |> render_change(%{"resolver_type" => "custom_do53"})

    # Add a custom server
    lv
    |> form("form", %{
      account: %{
        config: %{
          upstream_do53: %{"0" => %{"address" => "8.8.8.8"}},
          upstream_doh_provider: ""
        }
      }
    })
    |> render_submit()

    # Verify DoH provider is cleared and Do53 is set
    account = Domain.Accounts.fetch_account_by_id!(account.id)
    assert account.config.upstream_doh_provider == nil
    assert length(account.config.upstream_do53) == 1
    assert hd(account.config.upstream_do53).address == "8.8.8.8"
  end
end
