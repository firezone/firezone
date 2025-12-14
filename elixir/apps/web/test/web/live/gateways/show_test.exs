defmodule Web.Live.Gateways.ShowTest do
  use Web.ConnCase, async: true

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.GatewayFixtures
  import Domain.TokenFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    gateway = gateway_fixture(account: account)
    gateway = Repo.preload(gateway, :site)

    %{
      account: account,
      actor: actor,
      gateway: gateway
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    gateway: gateway,
    conn: conn
  } do
    path = ~p"/#{account}/gateways/#{gateway}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "raises NotFoundError for deleted gateway", %{
    account: account,
    actor: actor,
    gateway: gateway,
    conn: conn
  } do
    Repo.delete!(gateway)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/gateways/#{gateway}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    gateway: gateway,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/gateways/#{gateway}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ gateway.site.name
    assert breadcrumbs =~ gateway.name
  end

  test "renders gateway details", %{
    account: account,
    actor: actor,
    gateway: gateway,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/gateways/#{gateway}")

    table =
      lv
      |> element("#gateway")
      |> render()
      |> vertical_table_to_map()

    assert table["site"] =~ gateway.site.name
    assert table["name"] =~ gateway.name
    assert table["last started"]
    assert table["last seen remote ip"] =~ to_string(gateway.last_seen_remote_ip)
    assert table["status"] =~ "Offline"
    assert table["version"] =~ gateway.last_seen_version
    assert table["user agent"] =~ gateway.last_seen_user_agent
    assert table["tunnel interface ipv4 address"] =~ to_string(gateway.ipv4)
    assert table["tunnel interface ipv6 address"] =~ to_string(gateway.ipv6)
  end

  test "renders gateway status", %{
    account: account,
    actor: actor,
    gateway: gateway,
    conn: conn
  } do
    gateway_token = gateway_token_fixture(site: gateway.site, account: account)
    :ok = Domain.Presence.Gateways.connect(gateway, gateway_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/gateways/#{gateway}")

    table =
      lv
      |> element("#gateway")
      |> render()
      |> vertical_table_to_map()

    assert table["status"] =~ "Online"
  end

  test "allows deleting gateways", %{
    account: account,
    actor: actor,
    gateway: gateway,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/gateways/#{gateway}")

    lv
    |> element("button[type=submit]", "Delete Gateway")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/sites/#{gateway.site}")

    refute Repo.get_by(Domain.Gateway, id: gateway.id, account_id: gateway.account_id)
  end

  test "updates gateway status on presence event", %{
    account: account,
    actor: actor,
    gateway: gateway,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/gateways/#{gateway}")

    :ok = Domain.Presence.Gateways.Site.subscribe(gateway.site.id)
    gateway_token = gateway_token_fixture(site: gateway.site, account: account)
    :ok = Domain.Presence.Gateways.connect(gateway, gateway_token.id)
    assert_receive %{topic: "presences:sites:" <> _}

    table =
      lv
      |> element("#gateway")
      |> render()
      |> vertical_table_to_map()

    assert table["status"] =~ "Online"
  end
end
