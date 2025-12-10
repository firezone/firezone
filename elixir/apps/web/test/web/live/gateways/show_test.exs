defmodule Web.Live.Gateways.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    gateway = Fixtures.Gateways.create_gateway(account: account, actor: actor, identity: identity)
    gateway = Repo.preload(gateway, :site)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
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
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "raises NotFoundError for deleted gateway", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    gateway = Fixtures.Gateways.delete_gateway(gateway)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ gateway.site.name
    assert breadcrumbs =~ gateway.name
  end

  test "renders gateway details", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
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
    assert table["user agent"] =~ gateway.last_seen_user_agent
    assert table["version"] =~ gateway.last_seen_version
  end

  test "renders gateway status", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    gateway_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
    :ok = Domain.Presence.Gateways.connect(gateway, gateway_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
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
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    lv
    |> element("button[type=submit]", "Delete Gateway")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/sites/#{gateway.site}")

    refute Repo.get(Domain.Gateways.Gateway, gateway.id)
  end

  test "updates gateway status on presence event", %{
    account: account,
    gateway: gateway,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/gateways/#{gateway}")

    :ok = Domain.Presence.Gateways.Site.subscribe(gateway.site.id)
    gateway_token = Fixtures.Sites.create_token(site: gateway.site, account: account)
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
