defmodule Web.Auth.SettingsLive.IdentityProviders.GoogleWorkspace.ShowTest do
  use Web.ConnCase, async: true
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = AccountsFixtures.create_account()
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} =
      AuthFixtures.start_openid_providers(["google"])
      |> AuthFixtures.create_google_workspace_provider(account: account)

    identity = AuthFixtures.create_identity(account: account, actor: actor, provider: provider)

    %{
      account: account,
      actor: actor,
      provider: provider,
      identity: identity,
      bypass: bypass
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    provider: provider,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders provider details", %{
    account: account,
    actor: actor,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    inserted_at = Cldr.DateTime.to_string!(provider.inserted_at, Web.CLDR, format: :short)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert has_element?(lv, "a", "Edit Identity Provider")
    assert has_element?(lv, "button", "Reconnect Identity Provider")

    active =
      lv
      |> element("table")
      |> render()

    assert table_to_text(active) == [
             [provider.name],
             ["Active"],
             [provider.adapter_config["client_id"]],
             ["#{inserted_at} by System"]
           ]

    disabled =
      lv
      |> element("button", "Disable Identity Provider")
      |> render_click()
      |> Floki.find("table")

    assert table_to_text(disabled) == [
             [provider.name],
             ["Disabled"],
             [provider.adapter_config["client_id"]],
             ["#{inserted_at} by System"]
           ]

    provider
    |> Ecto.Changeset.change(
      created_by: :identity,
      created_by_identity_id: identity.id
    )
    |> Repo.update!()

    enabled =
      lv
      |> element("button", "Enable Identity Provider")
      |> render_click()
      |> Floki.find("table")

    assert table_to_text(enabled) == [
             [provider.name],
             ["Active"],
             [provider.adapter_config["client_id"]],
             ["#{inserted_at} by #{actor.name}"]
           ]

    assert lv
           |> element("button", "Delete Identity Provider")
           |> render_click() ==
             {:error, {:redirect, %{to: ~p"/#{account}/settings/identity_providers"}}}
  end
end
