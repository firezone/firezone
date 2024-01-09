defmodule Web.Live.Settings.IdentityProviders.OpenIDConnect.NewTest do
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
    path = ~p"/#{account}/settings/identity_providers/openid_connect/new"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
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
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    provider_adapter_config =
      Fixtures.Auth.openid_connect_adapter_config(
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

    provider_adapter_config = Map.drop(provider_adapter_config, ["response_type"])

    provider_attrs =
      Fixtures.Auth.provider_attrs(
        adapter: :openid_connect,
        adapter_config: provider_adapter_config
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

    render_submit(form)
    assert provider = Repo.get_by(Domain.Auth.Provider, name: provider_attrs.name)

    assert_redirected(
      lv,
      ~p"/#{account.id}/settings/identity_providers/openid_connect/#{provider}/redirect"
    )

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
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    provider_adapter_config =
      Fixtures.Auth.openid_connect_adapter_config(
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

    provider_adapter_config = Map.drop(provider_adapter_config, ["response_type"])

    provider_attrs =
      Fixtures.Auth.provider_attrs(
        adapter: :openid_connect,
        adapter_config: provider_adapter_config
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

    changed_values = %{
      provider: %{
        name: String.duplicate("a", 256),
        adapter_config: %{provider_attrs.adapter_config | "client_id" => ""}
      }
    }

    validate_change(form, changed_values, fn form, html ->
      assert form_validation_errors(form) == %{
               "provider[name]" => ["should be at most 255 character(s)"],
               "provider[adapter_config][client_id]" => ["can't be blank"]
             }

      assert html
             |> Floki.find("div[phx-feedback-for='provider[adapter_config][client_id]'] p")
             |> Floki.text() =~ "can't be blank"
    end)
  end
end
