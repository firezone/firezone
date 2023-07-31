defmodule Web.Auth.Settings.IdentityProviders.OpenIDConnect.NewTest do
  use Web.ConnCase, async: true
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = AccountsFixtures.create_account()
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
    identity = AuthFixtures.create_identity(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/settings/identity_providers/openid_connect/new") ==
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
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/new")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "provider[adapter_config][_persistent_id]",
             "provider[adapter_config][client_id]",
             "provider[adapter_config][client_secret]",
             "provider[adapter_config][discovery_document_uri]",
             "provider[adapter_config][response_type]",
             "provider[adapter_config][scope]",
             "provider[name]"
           ]
  end

  test "creates a new provider on valid attrs", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {_bypass, [adapter_config_attrs]} = AuthFixtures.start_openid_providers(["google"])
    adapter_config_attrs = Map.drop(adapter_config_attrs, ["response_type"])

    provider_attrs =
      AuthFixtures.provider_attrs(
        adapter: :openid_connect,
        adapter_config: adapter_config_attrs
      )

    bypass = Bypass.open()
    Bypass.down(bypass)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/new")

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
                   ~p"/#{account}/settings/identity_providers/openid_connect/#{provider}/redirect"
               }}}

    assert provider.name == provider_attrs.name
    assert provider.adapter == :openid_connect

    assert provider.adapter_config == %{
             "client_id" => provider_attrs.adapter_config["client_id"],
             "client_secret" => provider_attrs.adapter_config["client_secret"],
             "discovery_document_uri" => provider_attrs.adapter_config["discovery_document_uri"],
             "scope" => provider_attrs.adapter_config["scope"],
             "response_type" => "code"
           }
  end

  test "renders changeset errors on invalid attrs", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {_bypass, [adapter_config_attrs]} = AuthFixtures.start_openid_providers(["google"])
    adapter_config_attrs = Map.drop(adapter_config_attrs, ["response_type"])

    provider_attrs =
      AuthFixtures.provider_attrs(
        adapter: :openid_connect,
        adapter_config: adapter_config_attrs
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/new")

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
