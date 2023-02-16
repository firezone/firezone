defmodule FzHttpWeb.SettingLive.SecurityTest do
  use FzHttpWeb.ConnCase, async: true
  import FzHttp.SAMLIdentityProviderFixtures
  alias FzHttpWeb.SettingLive.Security

  describe "authenticated mount" do
    test "loads the active sessions table", %{admin_conn: conn} do
      path = ~p"/settings/security"
      {:ok, _view, html} = live(conn, path)

      assert html =~ "<h4 class=\"title is-4\">Authentication</h4>"
    end

    test "selects the chosen option", %{admin_conn: conn} do
      path = ~p"/settings/security"
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s|<option selected="selected" value="0">Never</option>|

      FzHttp.Config.put_config!(:vpn_session_duration, 3_600)

      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s|<option selected="selected" value="3600">Every Hour</option>|
    end
  end

  describe "unauthenticated mount" do
    test "redirects to not authorized", %{unauthed_conn: conn} do
      path = ~p"/settings/security"
      expected_path = ~p"/"

      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "session_duration_options/0" do
    test "displays the correct session duration integers" do
      assert Security.session_duration_options({{:db, :foo}, 3_600}) == [
               {"Never", 0},
               {"Once", 2_147_483_647},
               {"Every Hour", 3600},
               {"Every Day", 86400},
               {"Every Week", 604_800},
               {"Every 30 Days", 2_592_000},
               {"Every 90 Days", 7_776_000}
             ]

      assert Security.session_duration_options({{:env, "FOO"}, 1234}) == [
               {"Never", 0},
               {"Once", 2_147_483_647},
               {"Every Hour", 3600},
               {"Every Day", 86400},
               {"Every Week", 604_800},
               {"Every 30 Days", 2_592_000},
               {"Every 90 Days", 7_776_000},
               {"Every 1234 seconds", 1234}
             ]
    end
  end

  describe "toggles" do
    import FzHttp.ConfigFixtures

    setup %{conf_key: key, conf_val: val} do
      FzHttp.Config.put_config!(key, val)
      {:ok, path: ~p"/settings/security"}
    end

    for {key, val} <- [
          local_auth_enabled: true,
          allow_unprivileged_device_management: true,
          allow_unprivileged_device_configuration: true,
          disable_vpn_on_oidc_error: true
        ] do
      @tag conf_key: key, conf_val: val
      test "toggle #{key} when value in db is true", %{admin_conn: conn, path: path} do
        {:ok, view, _html} = live(conn, path)
        html = view |> element("input[phx-value-config=#{unquote(key)}}]") |> render()
        assert html =~ "checked"

        view |> element("input[phx-value-config=#{unquote(key)}]") |> render_click()
        assert FzHttp.Config.fetch_config!(unquote(key)) == false
      end
    end

    for {key, val} <- [
          local_auth_enabled: false,
          allow_unprivileged_device_management: false,
          allow_unprivileged_device_configuration: false,
          disable_vpn_on_oidc_error: false
        ] do
      @tag conf_key: key, conf_val: val
      test "toggle #{key} when value in db is false", %{admin_conn: conn, path: path} do
        {:ok, view, _html} = live(conn, path)
        html = view |> element("input[phx-value-config=#{unquote(key)}]") |> render()
        refute html =~ "checked"

        view |> element("input[phx-value-config=#{unquote(key)}]") |> render_click()
        assert FzHttp.Config.fetch_config!(unquote(key)) == true
      end
    end
  end

  describe "oidc configuration" do
    import FzHttp.ConfigFixtures

    setup %{admin_conn: conn} do
      configuration(%{
        openid_connect_providers: [
          %{
            "id" => "test",
            "label" => "test123",
            "client_id" => "foo",
            "client_secret" => "bar",
            "discovery_document_uri" =>
              "https://common.auth0.com/.well-known/openid-configuration",
            "auto_create_users" => false
          },
          %{
            "id" => "test2",
            "label" => "test2",
            "client_id" => "foo2",
            "client_secret" => "bar2",
            "discovery_document_uri" =>
              "https://common.auth0.com/.well-known/openid-configuration",
            "auto_create_users" => false
          }
        ],
        saml_identity_providers: []
      })

      path = ~p"/settings/security"
      {:ok, view, _html} = live(conn, path)
      [view: view]
    end

    test "click add button", %{view: view} do
      html =
        view
        |> element("a", "Add OpenID Connect Provider")
        |> render_click()

      assert html =~ ~s|<p class="modal-card-title">OIDC Configuration</p>|
    end

    test "click edit button", %{view: view} do
      html =
        view
        |> element("a[href=\"/settings/security/oidc/test/edit\"]", "Edit")
        |> render_click()

      assert html =~ ~s|<p class="modal-card-title">OIDC Configuration</p>|
      assert html =~ ~s|value="test123"|
    end

    test "validate", %{view: view} do
      view
      |> element("a[href=\"/settings/security/oidc/test/edit\"]", "Edit")
      |> render_click()

      return =
        view
        |> form("#oidc-form")
        |> render_submit(%{
          open_id_connect_provider: %{
            label: "updated"
          }
        })

      assert {:error, {:redirect, _}} = return

      assert %FzHttp.Config.Configuration.OpenIDConnectProvider{
               id: "test",
               label: "updated",
               scope: "openid email profile",
               response_type: "code",
               client_id: "foo",
               client_secret: "bar",
               discovery_document_uri:
                 "https://common.auth0.com/.well-known/openid-configuration",
               redirect_uri: nil,
               auto_create_users: false
             } in FzHttp.Config.fetch_config!(:openid_connect_providers)
    end

    test "delete", %{view: view} do
      view
      |> element("button[phx-value-key=\"test\"]", "Delete")
      |> render_click()

      openid_connect_providers = FzHttp.Config.fetch_config!(:openid_connect_providers)
      assert Enum.map(openid_connect_providers, & &1.id) == ["test2"]

      view
      |> element("button[phx-value-key=\"test2\"]", "Delete")
      |> render_click()

      assert FzHttp.Config.fetch_config!(:openid_connect_providers) == []
    end
  end

  describe "saml configuration" do
    import FzHttp.ConfigFixtures

    setup %{admin_conn: conn} do
      # Security views use the DB config, not cached config, so update DB here for testing
      saml_attrs1 = saml_attrs()
      saml_attrs2 = saml_attrs() |> Map.put("id", "test2") |> Map.put("label", "test2")

      configuration(%{
        openid_connect_providers: [],
        saml_identity_providers: [saml_attrs1, saml_attrs2]
      })

      path = ~p"/settings/security"
      {:ok, view, _html} = live(conn, path)
      [view: view]
    end

    test "click add button", %{view: view} do
      html =
        view
        |> element("a", "Add SAML Identity Provider")
        |> render_click()

      assert html =~ ~s|<p class="modal-card-title">SAML Configuration</p>|

      html =
        view
        |> form("#saml-form", %{
          saml_identity_provider: %{
            metadata: "XXX",
            label: ""
          }
        })
        |> render_submit()

      assert html =~ "{:fatal, {:expected_element_start_tag,"
      assert html =~ "can&#39;t be blank"

      attrs = saml_attrs()

      return =
        view
        |> form("#saml-form", %{
          saml_identity_provider: %{
            id: "FAKEID",
            metadata: attrs["metadata"],
            label: "FOO"
          }
        })
        |> render_submit()

      assert {:error, {:redirect, _}} = return

      saml_identity_providers = FzHttp.Config.fetch_config!(:saml_identity_providers)

      assert length(saml_identity_providers) == 3

      assert %FzHttp.Config.Configuration.SAMLIdentityProvider{
               auto_create_users: false,
               # XXX this field would be nil if we don't "guess" the url when we load the record in StartProxy
               base_url: "#{FzHttp.Config.fetch_env!(:fz_http, :external_url)}auth/saml",
               id: "FAKEID",
               label: "FOO",
               metadata: attrs["metadata"],
               sign_metadata: true,
               sign_requests: true,
               signed_assertion_in_resp: true,
               signed_envelopes_in_resp: true
             } in saml_identity_providers
    end

    test "edit", %{view: view} do
      html =
        view
        |> element("a[href=\"/settings/security/saml/test/edit\"]", "Edit")
        |> render_click()

      assert html =~ ~s|<p class="modal-card-title">SAML Configuration</p>|
      assert html =~ ~s|entityID=&quot;http://localhost:8080/realms/firezone|
      assert html =~ ~s|<input class="input " id="saml-form_label"|

      redirect =
        view
        |> form("#saml-form")
        |> render_submit(%{
          "saml_identity_provider" => %{
            id: "new_id",
            label: "new_label",
            base_url: "http://example.com/realms/firezone",
            metadata: saml_attrs()["metadata"]
          }
        })

      assert {:error, {:redirect, %{flash: _, to: "/settings/security"}}} = redirect

      assert saml_identity_provider =
               FzHttp.Config.fetch_config!(:saml_identity_providers)
               |> Enum.find(fn saml_identity_provider ->
                 saml_identity_provider.id == "new_id"
               end)

      assert saml_identity_provider.id == "new_id"
      assert saml_identity_provider.label == "new_label"
      assert saml_identity_provider.base_url == "http://example.com/realms/firezone"
    end

    test "validate", %{view: view} do
      attrs = saml_attrs()

      view
      |> element("a[href=\"/settings/security/saml/test/edit\"]", "Edit")
      |> render_click()

      html =
        view
        |> element("#saml-form")
        |> render_submit(%{"metadata" => "updated"})

      # stays on the modal
      assert html =~ ~s|<p class="modal-card-title">SAML Configuration</p>|

      assert %FzHttp.Config.Configuration.SAMLIdentityProvider{
               auto_create_users: true,
               base_url: "#{FzHttp.Config.fetch_env!(:fz_http, :external_url)}auth/saml",
               id: attrs["id"],
               label: attrs["label"],
               metadata: attrs["metadata"],
               sign_metadata: true,
               sign_requests: true,
               signed_assertion_in_resp: true,
               signed_envelopes_in_resp: true
             } in FzHttp.Config.fetch_config!(:saml_identity_providers)
    end

    test "delete", %{view: view} do
      view
      |> element("button[phx-value-key=\"test\"]", "Delete")
      |> render_click()

      saml_identity_providers = FzHttp.Config.fetch_config!(:saml_identity_providers)
      assert Enum.map(saml_identity_providers, & &1.id) == ["test2"]

      view
      |> element("button", "Delete")
      |> render_click()

      assert FzHttp.Config.fetch_config!(:saml_identity_providers) == []
    end
  end
end
