defmodule Web.Auth.SettingsLive.IdentityProviders.GoogleWorkspace.EditTest do
  use Web.ConnCase, async: true
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = AccountsFixtures.create_account()

    {provider, bypass} =
      AuthFixtures.start_openid_providers(["google"])
      |> AuthFixtures.create_google_workspace_provider(account: account)

    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
    identity = AuthFixtures.create_identity(account: account, actor: actor)

    %{
      bypass: bypass,
      account: account,
      provider: provider,
      actor: actor,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    provider: provider,
    conn: conn
  } do
    assert live(
             conn,
             ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/edit"
           ) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders provider creation form", %{
    account: account,
    identity: identity,
    provider: provider,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "provider[adapter_config][_persistent_id]",
             "provider[adapter_config][client_id]",
             "provider[adapter_config][client_secret]",
             "provider[name]"
           ]
  end

  test "creates a new provider on valid attrs", %{
    account: account,
    identity: identity,
    provider: provider,
    conn: conn
  } do
    {_bypass, [adapter_config_attrs]} = AuthFixtures.start_openid_providers(["google"])

    adapter_config_attrs =
      Map.drop(adapter_config_attrs, [
        "response_type",
        "discovery_document_uri",
        "scope"
      ])

    provider_attrs =
      AuthFixtures.provider_attrs(
        adapter: :google_workspace,
        adapter_config: adapter_config_attrs
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/edit")

    form =
      lv
      |> form("form",
        provider: %{
          name: provider_attrs.name,
          adapter_config: provider_attrs.adapter_config
        }
      )

    result = render_submit(form)
    assert provider = Domain.Repo.get_by(Domain.Auth.Provider, name: provider_attrs.name)

    assert result ==
             {:error,
              {:redirect,
               %{
                 to:
                   ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/redirect"
               }}}

    assert provider.name == provider_attrs.name
    assert provider.adapter == :google_workspace

    assert provider.adapter_config["client_id"] == adapter_config_attrs["client_id"]
    assert provider.adapter_config["client_secret"] == adapter_config_attrs["client_secret"]
  end

  test "renders changeset errors on invalid attrs", %{
    account: account,
    identity: identity,
    provider: provider,
    conn: conn
  } do
    {_bypass, [adapter_config_attrs]} = AuthFixtures.start_openid_providers(["google"])

    adapter_config_attrs =
      Map.drop(adapter_config_attrs, [
        "response_type",
        "discovery_document_uri",
        "scope"
      ])

    provider_attrs =
      AuthFixtures.provider_attrs(
        adapter: :google_workspace,
        adapter_config: adapter_config_attrs
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/edit")

    form =
      form(lv, "form",
        provider: %{
          name: provider_attrs.name,
          adapter_config: provider_attrs.adapter_config
        }
      )

    validate_change(form, %{provider: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "provider[name]" => ["should be at most 255 character(s)"]
             }
    end)
  end
end
