defmodule Web.Live.Settings.IdentityProviders.GoogleWorkspace.NewTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

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
    path = ~p"/#{account}/settings/identity_providers/google_workspace/new"

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
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/new")

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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/new")

    form =
      form(lv, "form",
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

    assert provider.adapter_config["client_id"] ==
             provider_attrs.adapter_config["client_id"]

    assert provider.adapter_config["client_secret"] ==
             provider_attrs.adapter_config["client_secret"]
  end

  test "renders changeset errors on invalid attrs", %{
    account: account,
    identity: identity,
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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/new")

    form =
      form(lv, "form",
        provider: %{
          name: provider_attrs.name,
          adapter_config: provider_attrs.adapter_config
        }
      )

    changed_values = %{
      provider: %{
        name: String.duplicate("a", 256),
        adapter_config: %{provider_attrs.adapter_config | "client_id" => ""}
      }
    }

    validate_change(form, changed_values, fn form, _html ->
      assert form_validation_errors(form) == %{
               "provider[name]" => ["should be at most 255 character(s)"],
               "provider[adapter_config][client_id]" => ["can't be blank"]
             }
    end)
  end
end
