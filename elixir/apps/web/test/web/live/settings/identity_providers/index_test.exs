defmodule Web.Live.Settings.IdentityProviders.IndexTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} = Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

    identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
    subject = Fixtures.Auth.create_subject(identity: identity)

    %{
      account: account,
      actor: actor,
      openid_connect_provider: provider,
      bypass: bypass,
      identity: identity,
      subject: subject
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/identity_providers"

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
      |> live(~p"/#{account}/settings/identity_providers")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Identity Providers"
  end

  test "renders add provider button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers")

    assert button = Floki.find(html, "a[href='/#{account.slug}/settings/identity_providers/new']")
    assert Floki.text(button) =~ "Add Identity Provider"
  end

  test "renders default provider form", %{account: account, identity: identity, conn: conn} do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers")

    assert Floki.text(html) =~ "Default Authentication Provider"
    assert form = Floki.find(html, "form#default-provider-form")

    assert Floki.text(form) =~
             "When selected, users signing in from the Firezone client will be taken directly to this provider for authentication."
  end

  test "allows setting a default provider", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} = Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers")

    assert Floki.text(html) =~ "Default Authentication Provider"

    html =
      lv
      |> form("#default-provider-form", %{
        "provider_id" => provider.id
      })
      |> render_submit()

    # Assert the default provider is set
    assert html
           |> Floki.find("option[selected]")
           |> Floki.attribute("value") == [to_string(provider.id)]
  end

  test "allows clearing the default provider", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_openid_connect_provider(
        account: account,
        assigned_default_at: DateTime.utc_now()
      )

    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers")

    assert Floki.text(html) =~ "Default Authentication Provider"

    html =
      lv
      |> form("#default-provider-form", %{
        "provider_id" => "none"
      })
      |> render_submit()

    # Assert the default provider is set
    assert html
           |> Floki.find("option[selected]")
           |> Floki.attribute("value") == ["none"]

    provider = Repo.reload(provider)
    assert is_nil(provider.assigned_default_at)
  end

  test "renders table with multiple providers", %{
    account: account,
    openid_connect_provider: openid_connect_provider,
    identity: identity,
    subject: subject,
    conn: conn
  } do
    email_provider = Fixtures.Auth.create_email_provider(account: account)
    {:ok, _email_provider} = Domain.Auth.disable_provider(email_provider, subject)
    userpass_provider = Fixtures.Auth.create_userpass_provider(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers")

    rows =
      lv
      |> element("#providers")
      |> render()
      |> table_to_map()

    assert length(rows) == 4

    rows
    |> with_table_row("name", openid_connect_provider.name, fn row ->
      assert row["type"] == "OpenID Connect"
      assert row["status"] =~ "Active"
      assert row["sync status"] =~ "Created 1 identity and 0 groups"
    end)
    |> with_table_row("name", email_provider.name, fn row ->
      assert row["type"] == "Email"
      assert row["status"] =~ "Disabled"
      assert row["sync status"] =~ "Created 0 identities and 0 groups"
    end)
    |> with_table_row("name", userpass_provider.name, fn row ->
      assert row["type"] == "Username & Password"
      assert row["status"] =~ "Active"
      assert row["sync status"] =~ "Created 0 identities and 0 groups"
    end)
  end

  test "renders google_workspace provider", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    conn = authorize_conn(conn, identity)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert row["type"] == "Google Workspace"
      assert row["status"] == "Active"
      assert row["sync status"] == "Never synced"
    end)

    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Actors.create_group(account: account, provider: provider)
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-1, :hour)
    provider |> Ecto.Changeset.change(last_synced_at: one_hour_ago) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert String.contains?(row["sync status"], "Synced 2 identities and 1 group 1 hour ago")
    end)

    provider =
      provider
      |> Ecto.Changeset.change(
        adapter_state: %{
          "refresh_token" => nil,
          "expires_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )
      |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert row["status"] =~ "No refresh token provided by IdP and access token expires on"
    end)

    provider
    |> Ecto.Changeset.change(
      disabled_at: DateTime.utc_now(),
      adapter_state: %{status: "pending_access_token"}
    )
    |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert row["status"] == "Provisioning Connect IdP"
    end)
  end

  test "shows provisioning status for openid_connect provider", %{
    account: account,
    openid_connect_provider: provider,
    identity: identity,
    conn: conn
  } do
    conn = authorize_conn(conn, identity)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert row["type"] == "OpenID Connect"
      assert row["status"] == "Active"
      assert row["sync status"] == "Created 1 identity and 0 groups"
    end)

    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Actors.create_group(account: account, provider: provider)
    provider |> Ecto.Changeset.change(last_synced_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert row["sync status"] == "Created 3 identities and 1 group"
    end)
  end

  test "shows provisioning status for other providers", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    provider = Fixtures.Auth.create_email_provider(account: account)

    conn = authorize_conn(conn, identity)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")

    lv
    |> element("#providers")
    |> render()
    |> table_to_map()
    |> with_table_row("name", provider.name, fn row ->
      assert row["type"] == "Email"
      assert row["status"] == "Active"
      assert row["sync status"] == "Created 0 identities and 0 groups"
    end)
  end
end
