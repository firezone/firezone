defmodule Web.Auth.Settings.IdentityProviders.IndexTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} =
      Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

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
    assert live(conn, ~p"/#{account}/settings/identity_providers") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders table with all providers", %{
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

    rows = lv |> element("tbody#providers") |> render() |> Floki.find("tr")
    rows_as_text = Enum.map(rows, &table_row_as_text_columns/1)

    assert length(rows_as_text) == 4

    assert [
             openid_connect_provider.name,
             "OpenID Connect",
             "Active",
             "Created 1 identity and 0 groups"
           ] in rows_as_text

    assert [
             email_provider.name,
             "Magic Link",
             "Disabled",
             "Created 0 identities and 0 groups"
           ] in rows_as_text

    assert [
             userpass_provider.name,
             "Username & Password",
             "Active",
             "Created 0 identities and 0 groups"
           ] in rows_as_text
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
    element = element(lv, "#providers-#{provider.id}")
    assert has_element?(element)

    row = render(element)

    assert table_row_as_text_columns(row) == [
             provider.name,
             "Google Workspace",
             "Active",
             "Never synced"
           ]

    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Actors.create_group(account: account, provider: provider)
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-1, :hour)
    provider |> Ecto.Changeset.change(last_synced_at: one_hour_ago) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")
    element = element(lv, "#providers-#{provider.id}")
    assert has_element?(element)

    row = render(element)

    assert table_row_as_text_columns(row) == [
             provider.name,
             "Google Workspace",
             "Active",
             "Synced 2 identities and 1 group 1 hour ago"
           ]

    provider
    |> Ecto.Changeset.change(
      disabled_at: DateTime.utc_now(),
      adapter_state: %{status: :pending_access_token}
    )
    |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")
    element = element(lv, "#providers-#{provider.id}")
    assert has_element?(element)

    row = render(element)

    assert table_row_as_text_columns(row) == [
             provider.name,
             "Google Workspace",
             "Pending access token, reconnect identity provider",
             "Synced 2 identities and 1 group 1 hour ago"
           ]
  end

  test "shows provisioning status for openid_connect provider", %{
    account: account,
    openid_connect_provider: provider,
    identity: identity,
    conn: conn
  } do
    conn = authorize_conn(conn, identity)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")
    element = element(lv, "#providers-#{provider.id}")
    assert has_element?(element)

    row = render(element)

    assert table_row_as_text_columns(row) == [
             provider.name,
             "OpenID Connect",
             "Active",
             "Created 1 identity and 0 groups"
           ]

    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Auth.create_identity(account: account, provider: provider)
    Fixtures.Actors.create_group(account: account, provider: provider)
    provider |> Ecto.Changeset.change(last_synced_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")
    element = element(lv, "#providers-#{provider.id}")
    assert has_element?(element)

    row = render(element)

    assert table_row_as_text_columns(row) == [
             provider.name,
             "OpenID Connect",
             "Active",
             "Created 3 identities and 1 group"
           ]
  end

  test "shows provisioning status for other providers", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    provider = Fixtures.Auth.create_token_provider(account: account)

    conn = authorize_conn(conn, identity)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/identity_providers")
    element = element(lv, "#providers-#{provider.id}")
    assert has_element?(element)

    row = render(element)

    assert table_row_as_text_columns(row) == [
             provider.name,
             "API Access Token",
             "Active",
             "Created 0 identities and 0 groups"
           ]
  end
end
