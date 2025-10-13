defmodule Web.Live.Settings.IdentityProviders.GoogleWorkspace.EditTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()

    {provider, bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

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
    path = ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
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
             "provider[adapter_config][service_account_json_key]",
             "provider[name]"
           ]
  end

  test "creates a new provider on valid attrs", %{
    account: account,
    identity: identity,
    provider: provider,
    conn: conn
  } do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config_attrs =
      Fixtures.Auth.openid_connect_adapter_config(
        discovery_document_uri:
          "http://localhost:#{bypass.port}/.well-known/openid-configuration",
        service_account_json_key:
          JSON.encode!(%{
            "type" => "service_account",
            "project_id" => "firezone-test",
            "private_key_id" => "e1fc5c12b490aaa1602f3de9133551952b749db3",
            "private_key" => "...",
            "client_email" => "firezone-idp-sync@firezone-test-391719.iam.gserviceaccount.com",
            "client_id" => "110986447653011314480",
            "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
            "token_uri" => "https://oauth2.googleapis.com/token",
            "auth_provider_x509_cert_url" => "https://www.googleapis.com/oauth2/v1/certs",
            "client_x509_cert_url" =>
              "https://www.googleapis.com/robot/v1/metadata/x509/firezone-idp-sync%40firezone-test-111111.iam.gserviceaccount.com",
            "universe_domain" => "googleapis.com"
          })
      )

    adapter_config_attrs =
      Map.drop(adapter_config_attrs, [
        "response_type",
        "discovery_document_uri",
        "scope"
      ])

    provider_attrs =
      Fixtures.Auth.provider_attrs(
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

    render_submit(form)
    assert provider = Repo.get_by(Domain.Auth.Provider, name: provider_attrs.name)

    assert_redirected(
      lv,
      ~p"/#{account.id}/settings/identity_providers/google_workspace/#{provider}/redirect"
    )

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
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config_attrs =
      Fixtures.Auth.openid_connect_adapter_config(
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

    adapter_config_attrs =
      Map.drop(adapter_config_attrs, [
        "response_type",
        "discovery_document_uri",
        "scope"
      ])

    provider_attrs =
      Fixtures.Auth.provider_attrs(
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

    adapter_config =
      Map.merge(provider_attrs.adapter_config, %{
        "client_id" => "",
        "service_account_json_key" => nil
      })

    changed_values = %{
      provider: %{
        name: String.duplicate("a", 256),
        adapter_config: adapter_config
      }
    }

    validate_change(form, changed_values, fn form, _html ->
      assert form_validation_errors(form) == %{
               "provider[name]" => ["should be at most 255 character(s)"],
               "provider[adapter_config][client_id]" => ["can't be blank"],
               "provider[adapter_config][service_account_json_key]" => ["is invalid"]
             }
    end)
  end
end
