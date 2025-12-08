defmodule Web.Live.Clients.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    client: client,
    conn: conn
  } do
    path = ~p"/#{account}/clients/#{client}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "raises NotFoundError for deleted client", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    client = Fixtures.Clients.delete_client(client)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Clients"
    assert breadcrumbs =~ client.name
  end

  test "renders client details", %{
    account: account,
    client: client,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    table =
      lv
      |> element("#client")
      |> render()
      |> vertical_table_to_map()

    assert table["id"] == client.id
    assert table["name"] == client.name
    assert table["owner"] =~ actor.name
    assert table["status"] =~ "Offline"
    assert table["created"]
    assert table["last started"]
    assert table["version"] =~ client.last_seen_version
    assert table["user agent"] =~ client.last_seen_user_agent

    table =
      lv
      |> element("#posture")
      |> render()
      |> vertical_table_to_map()

    assert table["file id"] == client.external_id

    assert table["verification"] =~ "Not Verified"
    assert table["device serial"] =~ to_string(client.device_serial)
    assert table["device uuid"] =~ to_string(client.device_uuid)
    assert table["app installation id"] =~ to_string(client.firebase_installation_id)
    assert table["last seen remote ip"] =~ to_string(client.last_seen_remote_ip)
  end

  test "shows client online status", %{
    account: account,
    actor: actor,
    client: client,
    identity: identity,
    conn: conn
  } do
    client_token =
      Fixtures.Tokens.create_client_token(account: account, actor: actor, identity: identity)

    :ok = Domain.Presence.Clients.connect(client, client_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    table =
      lv
      |> element("#client")
      |> render()
      |> vertical_table_to_map()

    assert table["status"] =~ "Online"
  end

  test "updates client online status using presence", %{
    account: account,
    client: client,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    :ok = Domain.Presence.Clients.Actor.subscribe(actor.id)

    client_token =
      Fixtures.Tokens.create_client_token(account: account, actor: actor, identity: identity)

    assert Domain.Presence.Clients.connect(client, client_token.id) == :ok
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:actor_clients:" <> _}

    wait_for(fn ->
      table =
        lv
        |> element("#client")
        |> render()
        |> vertical_table_to_map()

      assert table["status"] =~ "Online"
    end)
  end

  test "renders client owner", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    actor = Repo.preload(client, :actor).actor

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert lv
           |> element("#client")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("owner") =~ actor.name
  end

  test "renders policy_authorizations table", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    policy_authorization =
      Fixtures.PolicyAuthorizations.create_policy_authorization(
        account: account,
        client: client
      )

    policy_authorization =
      Repo.preload(policy_authorization, [:client, gateway: [:site], policy: [:group, :resource]])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    [row] =
      lv
      |> element("#policy_authorizations")
      |> render()
      |> table_to_map()

    assert row["authorized"]
    assert row["remote ip"] == to_string(client.last_seen_remote_ip)
    assert row["policy"] =~ policy_authorization.policy.group.name
    assert row["policy"] =~ policy_authorization.policy.resource.name

    assert row["gateway"] ==
             "#{policy_authorization.gateway.site.name}-#{policy_authorization.gateway.name} #{policy_authorization.gateway.last_seen_remote_ip}"
  end

  test "does not render policy_authorizations for deleted policies", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    policy_authorization =
      Fixtures.PolicyAuthorizations.create_policy_authorization(
        account: account,
        client: client
      )

    policy_authorization =
      Repo.preload(policy_authorization, [:client, gateway: [:site], policy: [:group, :resource]])

    Fixtures.Policies.delete_policy(policy_authorization.policy)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert [] =
             lv
             |> element("#policy_authorizations")
             |> render()
             |> table_to_map()
  end

  test "does not render policy_authorizations for deleted policy assocs", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    policy_authorization =
      Fixtures.PolicyAuthorizations.create_policy_authorization(
        account: account,
        client: client
      )

    policy_authorization =
      Repo.preload(policy_authorization, [:client, gateway: [:site], policy: [:group, :resource]])

    Fixtures.Actors.delete_group(policy_authorization.policy.group)
    Fixtures.Resources.delete_resource(policy_authorization.policy.resource)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert [] ==
             lv
             |> element("#policy_authorizations")
             |> render()
             |> table_to_map()
  end

  test "allows editing clients", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert lv
           |> element("a", "Edit")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/clients/#{client}/edit", kind: :push}}}
  end

  test "allows verifying clients", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert lv
           |> element("button[type=submit]", "Verify")
           |> render_click()

    table =
      lv
      |> element("#posture")
      |> render()
      |> vertical_table_to_map()

    refute table["verification"] =~ "Not"
    assert table["verification"] =~ "Verified"
    assert table["verification"] =~ "by"
  end

  test "allows deleting clients", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    lv
    |> element("button[type=submit]", "Delete Client")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/clients")

    refute Repo.get(Domain.Clients.Client, client.id)
  end

  test "renders current sign in method with auth_identity when client online", %{
    account: account,
    client: client,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    client_token =
      Fixtures.Tokens.create_client_token(account: account, actor: actor, identity: identity)

    :ok = Domain.Presence.Clients.connect(client, client_token.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    table =
      lv
      |> element("#client")
      |> render()
      |> vertical_table_to_map()

    assert table["current sign in method"] =~ identity.provider_identifier
  end

  test "renders offline message in current sign in method when client offline", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    table =
      lv
      |> element("#client")
      |> render()
      |> vertical_table_to_map()

    assert table["current sign in method"] == "Client is offline - sign in method unavailable"
  end
end
