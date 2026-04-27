defmodule PortalWeb.Settings.DNSTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Account

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/dns"

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
        |> live(~p"/#{account}/settings/dns")

      assert html =~ "DNS Configuration"
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
        |> live(~p"/#{account}/settings/dns")

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
        |> live(~p"/#{account}/settings/dns")

      assert html =~ "System DNS"
      assert html =~ "Use the device&#39;s default DNS resolvers."
    end
  end

  describe ":edit action" do
    test "renders edit panel and closes it", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/dns/edit")

      assert html =~ "Edit DNS Settings"
      assert html =~ "Add Resolver"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/dns")
    end

    test "closes edit panel on escape", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/dns/edit")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/dns")
    end

    test "switches to secure DNS and saves search domain", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/dns/edit")

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

      assert html =~ "DNS settings saved successfully"
      assert_patch(lv, ~p"/#{account}/settings/dns")

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
        |> live(~p"/#{account}/settings/dns/edit")

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

      assert html =~ "DNS settings saved successfully"

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
        |> live(~p"/#{account}/settings/dns/edit")

      html =
        lv
        |> form("#dns-form",
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
        |> live(~p"/#{account}/settings/dns/edit")

      html =
        lv
        |> form("#dns-form",
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
end
