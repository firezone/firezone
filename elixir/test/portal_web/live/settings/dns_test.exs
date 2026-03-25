defmodule PortalWeb.Live.Settings.DNSTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/dns"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "DNS Settings"
  end

  test "renders form with DNS type options", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{clients_upstream_dns: %{type: :system, addresses: []}}
    })

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "System DNS"
    assert html =~ "Secure DNS"
    assert html =~ "Custom DNS"
  end

  test "shows DoH provider dropdown when secure DNS selected", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :google, addresses: []}}
    })

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "DNS-over-HTTPS Provider"
    assert html =~ "Google Public DNS"
    assert html =~ "Cloudflare DNS"
    assert html =~ "Quad9 DNS"
    assert html =~ "OpenDNS"
  end

  test "shows custom DNS fields when custom type selected", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{
        clients_upstream_dns: %{
          type: :custom,
          addresses: [%{address: "8.8.8.8"}]
        }
      }
    })

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "IP Address"
    assert html =~ "8.8.8.8"
    assert html =~ "New Resolver"
  end

  test "saves search domain", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account =
      update_account(account, %{
        config: %{clients_upstream_dns: %{type: :system, addresses: []}}
      })

    attrs = %{
      account: %{
        config: %{
          search_domain: "example.com"
        }
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form[phx-submit]", attrs)
    |> render_submit()

    account = Repo.get!(Portal.Account, account.id)
    assert account.config.search_domain == "example.com"
  end

  test "renders error for invalid search domain", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account =
      update_account(account, %{
        config: %{clients_upstream_dns: %{type: :system, addresses: []}}
      })

    attrs = %{
      account: %{
        config: %{
          search_domain: "example"
        }
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form[phx-submit]", attrs)
           |> render_change() =~ "must be a valid fully-qualified domain name"
  end

  test "saves custom DNS server address", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{
        clients_upstream_dns: %{
          type: :custom,
          addresses: [%{address: "1.1.1.1"}]
        }
      }
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "custom",
            addresses: %{"0" => %{"address" => "8.8.8.8"}}
          }
        }
      }
    }

    lv
    |> form("form[phx-submit]", attrs)
    |> render_submit()

    account = Repo.get!(Portal.Account, account.id)
    assert account.config.clients_upstream_dns.type == :custom
    assert length(account.config.clients_upstream_dns.addresses) == 1
    assert hd(account.config.clients_upstream_dns.addresses).address == "8.8.8.8"
  end

  test "returns error when custom type has no addresses", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{clients_upstream_dns: %{type: :system, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form[phx-submit]", %{
             account: %{
               config: %{
                 clients_upstream_dns: %{
                   type: "custom"
                 }
               }
             }
           })
           |> render_submit() =~ "must have at least one custom resolver"
  end

  test "validates duplicate addresses", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form[phx-submit]", %{
             account: %{
               config: %{
                 clients_upstream_dns: %{
                   type: "custom",
                   addresses: %{
                     "0" => %{"address" => "8.8.8.8"},
                     "1" => %{"address" => "8.8.8.8"}
                   }
                 }
               }
             }
           })
           |> render_change() =~ "all addresses must be unique"
  end

  test "validates IP addresses", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form[phx-submit]", %{
             account: %{
               config: %{
                 clients_upstream_dns: %{
                   type: "custom",
                   addresses: %{"0" => %{"address" => "invalid"}}
                 }
               }
             }
           })
           |> render_change() =~ "must be a valid IP address"

    refute lv
           |> form("form[phx-submit]", %{
             account: %{
               config: %{
                 clients_upstream_dns: %{
                   type: "custom",
                   addresses: %{"0" => %{"address" => "8.8.8.8"}}
                 }
               }
             }
           })
           |> render_change() =~ "must be a valid IP address"
  end

  test "saves secure DNS with DoH provider", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :google, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form[phx-submit]", %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "secure",
            doh_provider: "google"
          }
        }
      }
    })
    |> render_submit()

    account = Repo.reload!(account)
    assert account.config.clients_upstream_dns.type == :secure
    assert account.config.clients_upstream_dns.doh_provider == :google
  end

  test "saves system resolver selection", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :cloudflare, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form[phx-submit]", %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "system"
          }
        }
      }
    })
    |> render_submit()

    account = Repo.get!(Portal.Account, account.id)
    assert account.config.clients_upstream_dns.type == :system
    assert Enum.empty?(account.config.clients_upstream_dns.addresses)
  end

  test "can add multiple custom DNS addresses", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "custom",
            addresses: %{
              "0" => %{"address" => "8.8.8.8"},
              "1" => %{"address" => "1.1.1.1"},
              "2" => %{"address" => "2001:4860:4860::8888"}
            }
          }
        }
      }
    }

    lv
    |> form("form[phx-submit]", attrs)
    |> render_submit()

    account = Repo.get!(Portal.Account, account.id)
    assert account.config.clients_upstream_dns.type == :custom
    assert length(account.config.clients_upstream_dns.addresses) == 3

    addresses = Enum.map(account.config.clients_upstream_dns.addresses, & &1.address)
    assert "8.8.8.8" in addresses
    assert "1.1.1.1" in addresses
    assert "2001:4860:4860::8888" in addresses
  end

  test "can change DoH provider", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :google, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form[phx-submit]", %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "secure",
            doh_provider: "cloudflare"
          }
        }
      }
    })
    |> render_submit()

    account = Repo.get!(Portal.Account, account.id)
    assert account.config.clients_upstream_dns.type == :secure
    assert account.config.clients_upstream_dns.doh_provider == :cloudflare
  end
end
