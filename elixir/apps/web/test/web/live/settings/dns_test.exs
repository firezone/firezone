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

  test "renders form with DNS type options", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{
      config: %{clients_upstream_dns: %{type: :system, addresses: []}}
    })

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "System DNS"
    assert html =~ "Secure DNS"
    assert html =~ "Custom DNS"
  end

  test "shows DoH provider dropdown when secure DNS selected", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :google, addresses: []}}
    })

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "DNS-over-HTTPS Provider"
    assert html =~ "Google Public DNS"
    assert html =~ "Cloudflare DNS"
    assert html =~ "Quad9 DNS"
    assert html =~ "OpenDNS"
  end

  test "shows custom DNS fields when custom type selected", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Fixtures.Accounts.update_account(account, %{
      config: %{
        clients_upstream_dns: %{
          type: :custom,
          addresses: [%{address: "8.8.8.8"}]
        }
      }
    })

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert html =~ "IP Address"
    assert html =~ "8.8.8.8"
    assert html =~ "New Resolver"
  end

  test "saves search domain", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account, %{
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
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    lv
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Repo.get!(Domain.Account, account.id)
    assert account.config.search_domain == "example.com"
  end

  test "renders error for invalid search domain", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account =
      Fixtures.Accounts.update_account(account, %{
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
    # Start with custom type and one address already configured
    Fixtures.Accounts.update_account(account, %{
      config: %{
        clients_upstream_dns: %{
          type: :custom,
          addresses: [%{address: "1.1.1.1"}]
        }
      }
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
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
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Repo.get!(Domain.Account, account.id)
    assert account.config.clients_upstream_dns.type == :custom
    assert length(account.config.clients_upstream_dns.addresses) == 1
    assert hd(account.config.clients_upstream_dns.addresses).address == "8.8.8.8"
  end

  test "returns error when custom type has no addresses", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with custom type but no addresses
    Fixtures.Accounts.update_account(account, %{
      config: %{clients_upstream_dns: %{type: :custom, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Try to submit without any addresses
    html =
      lv
      |> form("form", %{
        account: %{
          config: %{
            clients_upstream_dns: %{
              type: "custom"
            }
          }
        }
      })
      |> render_submit()

    assert html =~ "must have at least one custom resolver"
  end

  test "validates duplicate addresses", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form", %{
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
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    assert lv
           |> form("form", %{
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
           |> form("form", %{
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
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # First change just the type to make doh_provider field appear
    lv
    |> form("form", %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "secure"
          }
        }
      }
    })
    |> render_change()

    # Now submit with both type and doh_provider
    lv
    |> form("form", %{
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
    identity: identity,
    conn: conn
  } do
    # Start with secure DNS set
    Fixtures.Accounts.update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :cloudflare, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "system"
          }
        }
      }
    }

    lv
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Repo.get!(Domain.Account, account.id)
    assert account.config.clients_upstream_dns.type == :system
    assert Enum.empty?(account.config.clients_upstream_dns.addresses)
  end

  test "retains DoH provider when switching from secure to system and back", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with secure DNS
    Fixtures.Accounts.update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :quad9, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Switch to system
    render_change(lv, :change, %{
      "account" => %{
        "config" => %{
          "clients_upstream_dns" => %{
            "type" => "system"
          }
        }
      }
    })

    # Switch back to secure - DoH provider should still be there
    html =
      render_change(lv, :change, %{
        "account" => %{
          "config" => %{
            "clients_upstream_dns" => %{
              "type" => "secure",
              "doh_provider" => "quad9"
            }
          }
        }
      })

    assert html =~ "Quad9 DNS"
  end

  test "retains custom addresses when switching from custom to system and back", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with custom addresses
    Fixtures.Accounts.update_account(account, %{
      config: %{
        clients_upstream_dns: %{
          type: :custom,
          addresses: [%{address: "8.8.8.8"}]
        }
      }
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Switch to system
    render_change(lv, :change, %{
      "account" => %{
        "config" => %{
          "clients_upstream_dns" => %{
            "type" => "system"
          }
        }
      }
    })

    # Switch back to custom - addresses should still be there
    html =
      render_change(lv, :change, %{
        "account" => %{
          "config" => %{
            "clients_upstream_dns" => %{
              "type" => "custom",
              "addresses" => %{"0" => %{"address" => "8.8.8.8"}}
            }
          }
        }
      })

    assert html =~ "8.8.8.8"
  end

  test "can add multiple custom DNS addresses", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
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
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Repo.get!(Domain.Account, account.id)
    assert account.config.clients_upstream_dns.type == :custom
    assert length(account.config.clients_upstream_dns.addresses) == 3

    addresses = Enum.map(account.config.clients_upstream_dns.addresses, & &1.address)
    assert "8.8.8.8" in addresses
    assert "1.1.1.1" in addresses
    assert "2001:4860:4860::8888" in addresses
  end

  test "can change DoH provider", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    # Start with Google
    Fixtures.Accounts.update_account(account, %{
      config: %{clients_upstream_dns: %{type: :secure, doh_provider: :google, addresses: []}}
    })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/dns")

    # Change to Cloudflare
    attrs = %{
      account: %{
        config: %{
          clients_upstream_dns: %{
            type: "secure",
            doh_provider: "cloudflare"
          }
        }
      }
    }

    lv
    |> form("form", attrs)
    |> render_submit()

    account = Domain.Repo.get!(Domain.Account, account.id)
    assert account.config.clients_upstream_dns.type == :secure
    assert account.config.clients_upstream_dns.doh_provider == :cloudflare
  end
end
