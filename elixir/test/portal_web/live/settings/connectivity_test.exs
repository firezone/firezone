defmodule PortalWeb.Settings.ConnectivityTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.FeaturesFixtures

  alias Portal.Account

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/connectivity"

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
    test "renders custom upstream resolvers and unset search domain", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity")

      assert html =~ "Connectivity"
      assert html =~ "Not configured"
      assert html =~ "Custom DNS"
      assert html =~ "1.1.1.1"
      assert html =~ "2606:4700:4700::1111"
    end

    test "renders secure DNS provider details", %{conn: conn} do
      account =
        account_fixture(
          config: %{
            search_domain: "corp.example.com",
            clients_upstream_dns: %{type: :secure, doh_provider: :quad9}
          }
        )

      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity")

      assert html =~ "corp.example.com"
      assert html =~ "Secure DNS"
      assert html =~ "Quad9 DNS"
    end

    test "renders system DNS details", %{conn: conn} do
      account =
        account_fixture(
          config: %{
            clients_upstream_dns: %{type: :system}
          }
        )

      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity")

      assert html =~ "System DNS"
      assert html =~ "Use the device&#39;s default DNS resolvers."
    end
  end

  describe ":edit action" do
    test "renders edit panel and closes it", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      assert html =~ "Edit Connectivity Settings"
      assert html =~ "Add Resolver"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/connectivity")
    end

    test "closes edit panel on escape", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/connectivity")
    end

    test "switches to secure DNS and saves search domain", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      params = %{
        "account" => %{
          "config" => %{
            "search_domain" => "example.com",
            "clients_upstream_dns" => %{
              "type" => "secure",
              "doh_provider" => "cloudflare",
              "addresses" => %{
                "0" => %{"address" => "1.1.1.1"},
                "1" => %{"address" => "2606:4700:4700::1111"},
                "2" => %{"address" => "9.9.9.9"}
              },
              "addresses_sort" => ["0", "1", "2"],
              "addresses_drop" => [""]
            }
          }
        }
      }

      render_change(lv, "change", params)
      html = render_submit(lv, "submit", params)

      assert html =~ "Connectivity settings saved successfully"
      assert_patch(lv, ~p"/#{account}/settings/connectivity")

      assert %Account{} = saved = Repo.get!(Account, account.id)
      assert saved.config.search_domain == "example.com"
      assert saved.config.clients_upstream_dns.type == :secure
      assert saved.config.clients_upstream_dns.doh_provider == :cloudflare
    end

    test "adds and removes custom resolvers through the form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      html =
        render_change(lv, "change", %{
          "account" => %{
            "config" => %{
              "search_domain" => "dns.example.com",
              "clients_upstream_dns" => %{
                "type" => "custom",
                "addresses" => %{
                  "0" => %{"address" => "1.1.1.1"},
                  "1" => %{"address" => "8.8.8.8"}
                },
                "addresses_sort" => ["0", "1"],
                "addresses_drop" => [""]
              }
            }
          }
        })

      assert html =~ "1.1.1.1"
      assert html =~ "8.8.8.8"

      html =
        render_submit(lv, "submit", %{
          "account" => %{
            "config" => %{
              "search_domain" => "dns.example.com",
              "clients_upstream_dns" => %{
                "type" => "custom",
                "addresses" => %{
                  "0" => %{"address" => "8.8.8.8"}
                },
                "addresses_sort" => ["0"],
                "addresses_drop" => [""]
              }
            }
          }
        })

      assert html =~ "Connectivity settings saved successfully"

      assert %Account{} = saved = Repo.get!(Account, account.id)

      assert Enum.map(saved.config.clients_upstream_dns.addresses, & &1.address) == ["8.8.8.8"]
    end

    test "shows validation errors for invalid search domains", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      html =
        lv
        |> form("#connectivity-form",
          account: %{
            config: %{
              search_domain: ".bad.example.com",
              clients_upstream_dns: %{
                type: "system"
              }
            }
          }
        )
        |> render_change()

      assert html =~ "must not start with a dot"
    end

    test "shows validation error when custom DNS has duplicate resolvers", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      html =
        lv
        |> form("#connectivity-form",
          account: %{
            config: %{
              search_domain: "example.com",
              clients_upstream_dns: %{
                type: "custom",
                addresses: %{
                  "0" => %{address: "1.1.1.1"},
                  "1" => %{address: "1.1.1.1"}
                },
                addresses_sort: ["0", "1"],
                addresses_drop: [""]
              }
            }
          }
        )
        |> render_submit()

      assert html =~ "all addresses must be unique"
    end
  end

  describe "custom resolvers with no net change" do
    test "renders when adding then dropping a resolver leaves no net change", %{conn: conn} do
      # Starting from no custom resolvers, a change that adds an address and drops
      # it in the same event produces a net-empty list equal to the stored data, so
      # cast_embed leaves :addresses out of the changeset's changes while the raw
      # "addresses" params map remains. phoenix_ecto then surfaces that map as the
      # field value, which crashed the previous length/1 guard.
      account = account_fixture(config: %{clients_upstream_dns: %{type: :system}})
      actor = admin_actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      html =
        render_change(lv, "change", %{
          "account" => %{
            "config" => %{
              "clients_upstream_dns" => %{
                "type" => "custom",
                "addresses" => %{"0" => %{"address" => "1.1.1.1"}},
                "addresses_sort" => ["0"],
                "addresses_drop" => ["0"]
              }
            }
          }
        })

      assert html =~ "Add Resolver"
    end
  end

  describe "tunnel encryption" do
    test "is hidden when the global flag is off", %{conn: conn, account: account, actor: actor} do
      disable_feature(:aes_gcm)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity")

      refute html =~ "Tunnel Encryption"

      html = lv |> element("a", "Edit") |> render_click()
      refute html =~ "Use AES-256-GCM when supported"
    end

    test "is shown and toggleable when the global flag is on", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_feature(:aes_gcm)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity")

      assert html =~ "Tunnel Encryption"
      assert lv |> element("#tunnel-encryption") |> render() =~ "Disabled"

      html = lv |> element("a", "Edit") |> render_click()
      assert html =~ "Use AES-256-GCM when supported"

      html =
        lv
        |> form("#connectivity-form", account: %{config: %{aes_gcm: "true"}})
        |> render_submit()

      assert html =~ "Connectivity settings saved successfully"
      assert lv |> element("#tunnel-encryption") |> render() =~ "Used when supported"
      assert Repo.get!(Account, account.id).config.aes_gcm

      lv |> element("a", "Edit") |> render_click()

      lv
      |> form("#connectivity-form", account: %{config: %{aes_gcm: "false"}})
      |> render_submit()

      refute Repo.get!(Account, account.id).config.aes_gcm
    end

    test "rejects updates when the global flag is off", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_feature(:aes_gcm)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      disable_feature(:aes_gcm)

      html = render_submit(lv, "submit", %{"account" => %{"config" => %{"aes_gcm" => "true"}}})

      assert html =~ "Tunnel encryption settings are not available"
      refute Repo.get!(Account, account.id).config.aes_gcm
    end

    test "keeps DNS settings editable when the global flag is off", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      disable_feature(:aes_gcm)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/connectivity/edit")

      html =
        render_submit(lv, "submit", %{
          "account" => %{"config" => %{"search_domain" => "corp.example.com"}}
        })

      assert html =~ "Connectivity settings saved successfully"
      assert Repo.get!(Account, account.id).config.search_domain == "corp.example.com"
    end
  end

  describe "legacy DNS routes" do
    test "redirect to the connectivity settings", %{conn: conn, account: account, actor: actor} do
      conn = authorize_conn(conn, actor)

      assert redirected_to(get(conn, ~p"/#{account}/settings/dns")) ==
               ~p"/#{account}/settings/connectivity"

      assert redirected_to(get(conn, ~p"/#{account}/settings/dns/edit")) ==
               ~p"/#{account}/settings/connectivity/edit"
    end
  end
end
