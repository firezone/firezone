defmodule PortalWeb.Settings.DirectorySyncTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.OktaDirectoryFixtures

  alias Portal.Azure.ManagedIdentity
  alias Portal.Google.APIClient
  alias PortalWeb.Mocks

  setup do
    account = account_fixture(features: %{idp_sync: true})
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  defp open_directory_actions(lv, directory_id) do
    lv
    |> element("button[phx-click='toggle_directory_actions'][phx-value-id='#{directory_id}']")
    |> render_click()
  end

  defp has_directory_action_button?(html, event, directory_id) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("button[phx-click='#{event}'][phx-value-id='#{directory_id}']")
    |> Enum.any?()
  end

  defp verification_ref_from_open_url(lv) do
    assert_push_event(lv, "open_url", %{url: url})

    %{"state" => state} =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert {:ok, %{verification_ref: verification_ref, lv_pid: serialized_pid}} =
             PortalWeb.OIDC.verify_verification_state(state)

    assert PortalWeb.OIDC.deserialize_pid(serialized_pid) == lv.pid

    send(lv.pid, {:get_pending_verification, self()})

    assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}

    verification_ref
  end

  defp configure_google_directory_workload_identity do
    Portal.Config.put_env_override(
      :portal,
      APIClient,
      workload_identity_provider: "provider",
      workload_identity_audience: "audience",
      service_account_email: "sync@example.iam.gserviceaccount.com",
      service_account_key: nil
    )
  end

  defp configure_google_sync_authorization do
    Mocks.OIDC.stub_discovery_document()

    Portal.Config.put_env_override(:portal, Portal.Google.SyncAuthorization,
      client_id: "google-sync-authz-client-id",
      client_secret: "google-sync-authz-client-secret",
      response_type: "code",
      scope: "openid email",
      discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
      req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
    )
  end

  defp expect_google_directory_service_access(customer_id, domain) do
    test_pid = self()

    Req.Test.expect(ManagedIdentity, fn req_conn ->
      Req.Test.json(req_conn, %{
        "access_token" => "azure-managed-identity-token",
        "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
      })
    end)

    Req.Test.expect(APIClient, 7, fn req_conn ->
      send(test_pid, {:google_api_request, req_conn.request_path})

      case req_conn.request_path do
        "/v1/token" ->
          Req.Test.json(req_conn, %{
            "access_token" => "federated-google-token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })

        "/v1/projects/-/serviceAccounts/sync@example.iam.gserviceaccount.com:signJwt" ->
          Req.Test.json(req_conn, %{"signedJwt" => "google-signed-jwt"})

        "/token" ->
          Req.Test.json(req_conn, %{
            "access_token" => "delegated-google-token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })

        "/admin/directory/v1/customers/my_customer" ->
          Req.Test.json(req_conn, %{
            "id" => customer_id,
            "customerDomain" => domain
          })

        "/admin/directory/v1/users" ->
          Req.Test.json(req_conn, %{"users" => []})

        "/admin/directory/v1/groups" ->
          Req.Test.json(req_conn, %{"groups" => []})

        "/admin/directory/v1/customer/my_customer/orgunits" ->
          Req.Test.json(req_conn, %{"organizationUnits" => []})
      end
    end)
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/directory_sync"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "renders empty state when no directories exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Directory Sync"
      assert html =~ "No directories configured."
      assert html =~ "Add a directory"
    end

    test "renders directories with statuses and counts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      google_directory_fixture(%{
        account: account,
        name: "Corp Google",
        domain: "corp.example.com",
        is_verified: true
      })

      entra_directory_fixture(%{
        account: account,
        name: "Corp Entra",
        tenant_id: "tenant-123",
        is_disabled: true,
        disabled_reason: "Disabled by admin"
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Corp Google"
      assert html =~ "corp.example.com"
      assert html =~ "Active"
      assert html =~ "Corp Entra"
      assert html =~ "tenant-123"
      assert html =~ "Disabled"
    end

    test "shows upgrade state when idp_sync feature is disabled", %{conn: conn} do
      account = account_fixture(features: %{idp_sync: false})
      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Automate User &amp; Group Management"
      assert html =~ "Upgrade to Unlock"
      refute html =~ "No directories configured."
    end

    test "toggles, syncs, and deletes a directory", %{conn: conn, account: account, actor: actor} do
      directory =
        synced_google_directory_fixture(%{
          account: account,
          name: "Ops Google",
          domain: "ops.example.com",
          is_disabled: false,
          is_verified: true
        })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = render_click(lv, "toggle_directory", %{"id" => directory.id})
      assert html =~ "Directory disabled successfully."
      assert html =~ "Disabled"

      html = render_click(lv, "toggle_directory", %{"id" => directory.id})
      assert html =~ "Directory enabled successfully."
      assert html =~ "Active"

      html = render_click(lv, "sync_directory", %{"id" => directory.id})
      assert html =~ "Directory sync has been queued successfully."

      assert_enqueued(
        worker: Portal.Google.Sync,
        args: %{account_id: account.id, directory_id: directory.id}
      )

      html = render_click(lv, "delete_directory", %{"id" => directory.id})
      assert html =~ "Directory deleted successfully."
      refute html =~ "Ops Google"
    end

    test "sync rejects directories from other accounts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_directory = google_directory_fixture(name: "Other Account Google")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = render_click(lv, "sync_directory", %{"id" => other_directory.id})

      assert html =~ "Failed to queue directory sync."
      refute_enqueued(worker: Portal.Google.Sync)
    end

    test "closes the actions menu when navigating to edit", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory = google_directory_fixture(account: account, name: "Edit From Menu")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = open_directory_actions(lv, directory.id)
      assert has_directory_action_button?(html, "sync_directory", directory.id)

      lv
      |> element("a[href='/" <> "#{account.slug}/settings/directory_sync/google/#{directory.id}/edit']")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      html = render(lv)
      assert html =~ "Edit Edit From Menu"
      refute has_directory_action_button?(html, "sync_directory", directory.id)
    end
  end

  describe ":select_type action" do
    test "renders provider type selection and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/new")

      assert html =~ "Select Directory Type"
      assert html =~ "Google"
      assert html =~ "Entra"
      assert html =~ "Okta"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/directory_sync")
    end

    test "closes panel on escape keydown", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/new")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/directory_sync")
    end
  end

  describe ":new action" do
    test "renders new google directory form", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      assert html =~ "Add Google Directory"
      assert html =~ "Name"
      assert html =~ "Impersonation Email"
      assert html =~ "Verify Now"
    end


    test "requires an interactive Workspace administrator before marking Google verified", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      configure_google_directory_workload_identity()
      configure_google_sync_authorization()

      Req.Test.stub(ManagedIdentity, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      Req.Test.stub(APIClient, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      Req.Test.allow(ManagedIdentity, self(), lv.pid)
      Req.Test.allow(APIClient, self(), lv.pid)
      Req.Test.allow(PortalWeb.OIDC, self(), lv.pid)

      expect_google_directory_service_access("C0123", "verified.example.com")

      lv
      |> form("#directory-form",
        directory: %{
          name: "Google Directory",
          impersonation_email: "sync-admin@verified.example.com"
        }
      )
      |> render_change()

      lv
      |> element("button[phx-click='start_verification']")
      |> render_click()

      assert_push_event(lv, "open_url", %{url: url})
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      paths = drain_google_api_request_paths()
      customer_index = Enum.find_index(paths, &(&1 == "/admin/directory/v1/customers/my_customer"))
      users_index = Enum.find_index(paths, &(&1 == "/admin/directory/v1/users"))
      groups_index = Enum.find_index(paths, &(&1 == "/admin/directory/v1/groups"))

      orgunits_index =
        Enum.find_index(paths, &(&1 == "/admin/directory/v1/customer/my_customer/orgunits"))

      assert is_integer(customer_index)
      assert is_integer(users_index)
      assert is_integer(groups_index)
      assert is_integer(orgunits_index)
      assert customer_index < users_index
      assert users_index < groups_index
      assert groups_index < orgunits_index

      assert params["scope"] == "openid email"

      assert params["prompt"] == "select_account"
      assert params["code_challenge_method"] == "S256"

      assert {:ok, %{verification_ref: verification_ref}} =
               PortalWeb.OIDC.verify_verification_state(params["state"])

      send(lv.pid, {:get_pending_verification, self()})

      assert_receive {:pending_verification,
                      %{
                        type: "google_directory_sync",
                        verifier: verifier,
                        verification_ref: ^verification_ref,
                        workspace_customer_id: "C0123",
                        impersonation_email: "sync-admin@verified.example.com"
                      }}

      assert params["nonce"] == PortalWeb.OIDC.nonce(verifier)

      ack_ref = make_ref()

      send(
        lv.pid,
        {:google_directory_sync_complete, "verified.example.com", verification_ref,
         {self(), ack_ref}}
      )

      assert_receive {:verification_ack, ^ack_ref}

      html = render(lv)
      assert html =~ "Verified"
      assert html =~ "verified.example.com"

      lv |> element("form#directory-form") |> render_submit()

      assert %Portal.Google.Directory{domain: "verified.example.com", is_verified: true} =
               Portal.Repo.get_by(Portal.Google.Directory,
                 account_id: account.id,
                 name: "Google Directory"
               )
    end

    test "does not consume a Google directory verifier for a stale callback reference", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      configure_google_directory_workload_identity()
      configure_google_sync_authorization()

      Req.Test.stub(ManagedIdentity, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      Req.Test.stub(APIClient, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      Req.Test.allow(ManagedIdentity, self(), lv.pid)
      Req.Test.allow(APIClient, self(), lv.pid)
      Req.Test.allow(PortalWeb.OIDC, self(), lv.pid)
      expect_google_directory_service_access("C0123", "verified.example.com")

      lv
      |> form("#directory-form",
        directory: %{
          name: "Google Directory",
          impersonation_email: "sync-admin@verified.example.com"
        }
      )
      |> render_change()

      lv |> element("button[phx-click='start_verification']") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, %{verification_ref: verification_ref}} =
               PortalWeb.OIDC.verify_verification_state(state)

      send(lv.pid, {:get_pending_verification, Ecto.UUID.generate(), self()})
      assert_receive {:pending_verification, nil}

      send(lv.pid, {:peek_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}
    end

    test "rejects a Google verification completed after the impersonation email changes", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      configure_google_directory_workload_identity()
      configure_google_sync_authorization()

      Req.Test.stub(ManagedIdentity, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      Req.Test.stub(APIClient, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      Req.Test.allow(ManagedIdentity, self(), lv.pid)
      Req.Test.allow(APIClient, self(), lv.pid)
      Req.Test.allow(PortalWeb.OIDC, self(), lv.pid)

      expect_google_directory_service_access("C0123", "verified.example.com")

      lv
      |> form("#directory-form",
        directory: %{
          name: "Google Directory",
          impersonation_email: "original-admin@verified.example.com"
        }
      )
      |> render_change()

      lv |> element("button[phx-click='start_verification']") |> render_click()
      verification_ref = verification_ref_from_open_url(lv)

      lv
      |> form("#directory-form",
        directory: %{
          name: "Google Directory",
          impersonation_email: "changed-admin@attacker.example.com"
        }
      )
      |> render_change()

      ack_ref = make_ref()

      send(
        lv.pid,
        {:google_directory_sync_complete, "verified.example.com", verification_ref,
         {self(), ack_ref}}
      )

      assert_receive {:verification_ack, ^ack_ref}
      refute render(lv) =~ ">Verified<"
      assert has_element?(lv, "button[form='directory-form'][disabled]", "Create")
    end

    test "does not accept client-supplied Google verification fields", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      attrs = %{
        "name" => "Injected Google Directory",
        "impersonation_email" => "admin@victim.example.com",
        "domain" => "victim.example.com",
        "is_verified" => "true"
      }

      html = render_hook(lv, "validate", %{"directory" => attrs})

      refute html =~ ">Verified<"

      render_hook(lv, "submit_directory", %{})

      refute Portal.Repo.get_by(Portal.Google.Directory,
               account_id: account.id,
               name: "Injected Google Directory"
             )
    end

    test "shows a friendly error for incomplete Google workload identity configuration", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      Portal.Config.put_env_override(
        :portal,
        APIClient,
        workload_identity_provider: "provider",
        workload_identity_audience: nil,
        service_account_email: nil,
        service_account_key: nil
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form",
        directory: %{
          name: "Google Directory",
          impersonation_email: "admin@example.com"
        }
      )
      |> render_change()

      lv
      |> element("button[phx-click='start_verification']")
      |> render_click()

      html = render(lv)

      assert html =~ "Google Workspace workload identity configuration is incomplete."
      assert html =~ "GOOGLE_WORKLOAD_IDENTITY_AUDIENCE"
      refute html =~ ":incomplete_workload_identity_configuration"
    end

    test "unwraps Google federation responses into friendly verification errors", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      Portal.Config.put_env_override(
        :portal,
        APIClient,
        workload_identity_provider: "provider",
        workload_identity_audience: "audience",
        service_account_email: "sync@example.iam.gserviceaccount.com",
        service_account_key: nil
      )

      Req.Test.stub(ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      Req.Test.allow(ManagedIdentity, self(), lv.pid)
      Req.Test.allow(APIClient, self(), lv.pid)

      Req.Test.expect(ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "azure-managed-identity-token",
          "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
        })
      end)

      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "error" => "permission_denied",
          "error_description" => "Google denied the federated token exchange."
        })
      end)

      lv
      |> form("#directory-form",
        directory: %{
          name: "Google Directory",
          impersonation_email: "admin@example.com"
        }
      )
      |> render_change()

      lv
      |> element("button[phx-click='start_verification']")
      |> render_click()

      html = render(lv)

      assert html =~ "Google denied the federated token exchange."
      refute html =~ ":workload_identity_token_exchange"
      assert_push_event(lv, "close_open_url", %{})
    end

    test "generates an okta keypair and closes the panel", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      html = render_click(lv, "generate_keypair")
      assert html =~ "Public Key (JWK)"
      assert html =~ "okta-public-jwk"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/directory_sync")
    end

    test "does not consume an Entra directory verifier for a stale callback reference", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      lv |> element("button[phx-click='start_verification']") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, %{verification_ref: verification_ref}} =
               PortalWeb.OIDC.verify_verification_state(state)

      send(lv.pid, {:get_pending_verification, Ecto.UUID.generate(), self()})
      assert_receive {:pending_verification, nil}

      send(lv.pid, {:peek_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}
    end

    test "accepts only the active entra directory verification completion", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      lv |> element("button[phx-click='start_verification']") |> render_click()
      stale_ref = verification_ref_from_open_url(lv)

      lv |> element("button[phx-click='start_verification']") |> render_click()
      current_ref = verification_ref_from_open_url(lv)

      stale_ack_ref = make_ref()

      send(
        lv.pid,
        {:entra_directory_sync_complete, "stale-tenant", stale_ref, {self(), stale_ack_ref}}
      )

      assert_receive {:verification_ack, ^stale_ack_ref}

      html = render(lv)
      refute html =~ "Verified"
      refute html =~ "stale-tenant"

      current_ack_ref = make_ref()

      send(
        lv.pid,
        {:entra_directory_sync_complete, "current-tenant", current_ref,
         {self(), current_ack_ref}}
      )

      assert_receive {:verification_ack, ^current_ack_ref}

      html = render(lv)
      assert html =~ "Verified"
      assert html =~ "current-tenant"
    end

    test "queues the first sync after creating a verified entra directory", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      lv |> element("button[phx-click='start_verification']") |> render_click()
      verification_ref = verification_ref_from_open_url(lv)
      ack_ref = make_ref()

      send(
        lv.pid,
        {:entra_directory_sync_complete, "tenant-1", verification_ref, {self(), ack_ref}}
      )

      assert_receive {:verification_ack, ^ack_ref}

      lv
      |> form("#directory-form", directory: %{name: "Entra HQ"})
      |> render_change()

      render_hook(lv, "submit_directory", %{})

      directory = Portal.Repo.get_by!(Portal.Entra.Directory, account_id: account.id, name: "Entra HQ")
      assert directory.is_verified

      assert_enqueued(
        worker: Portal.Entra.Sync,
        args: %{account_id: account.id, directory_id: directory.id}
      )
    end

    test "cleans up webhook subscriptions when an entra directory is disabled or deleted", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory =
        entra_directory_fixture(%{
          account: account,
          name: "Entra Ops",
          tenant_id: "tenant-ops",
          users_subscription_id: "sub-users",
          groups_subscription_id: "sub-groups"
        })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = render_click(lv, "toggle_directory", %{"id" => directory.id})
      assert html =~ "Directory disabled successfully."

      assert_enqueued(
        worker: Portal.Entra.Subscriptions,
        args: %{
          action: "delete",
          tenant_id: "tenant-ops",
          subscription_ids: ["sub-users", "sub-groups"]
        }
      )

      html = render_click(lv, "delete_directory", %{"id" => directory.id})
      assert html =~ "Directory deleted successfully."
    end

    test "ignores entra directory completion after navigating to another form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      lv |> element("button[phx-click='start_verification']") |> render_click()
      verification_ref = verification_ref_from_open_url(lv)

      render_patch(lv, ~p"/#{account}/settings/directory_sync/google/new")

      ack_ref = make_ref()

      send(
        lv.pid,
        {:entra_directory_sync_complete, "stale-tenant", verification_ref, {self(), ack_ref}}
      )

      assert_receive {:verification_ack, ^ack_ref}

      html = render(lv)
      assert html =~ "Add Google Directory"
      refute html =~ "Verified"
      refute html =~ "stale-tenant"
    end
  end

  defp drain_google_api_request_paths(paths \\ []) do
    receive do
      {:google_api_request, path} -> drain_google_api_request_paths([path | paths])
    after
      0 -> Enum.reverse(paths)
    end
  end

  describe ":edit action" do
    test "renders edit form and closes on escape", %{conn: conn, account: account, actor: actor} do
      directory = google_directory_fixture(account: account, name: "Editable Google")

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      assert html =~ "Edit Editable Google"
      assert html =~ "Save"

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/directory_sync")
    end

    test "resets verification state for okta edit form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory =
        okta_directory_fixture(%{
          account: account,
          name: "Verified Okta",
          okta_domain: "verified.okta.com",
          is_verified: true
        })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      html = render_click(lv, "reset_verification")
      assert html =~ "Verify Now"
      refute html =~ "Verification complete"
    end

    test "keeps the Google authorization hook mounted while edit verification starts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      configure_google_directory_workload_identity()
      configure_google_sync_authorization()

      directory =
        google_directory_fixture(%{
          account: account,
          name: "Unverified Google",
          domain: "example.com",
          impersonation_email: "sync-admin@example.com",
          is_verified: false
        })

      Req.Test.stub(ManagedIdentity, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      Req.Test.stub(APIClient, fn req_conn ->
        Req.Test.json(req_conn, %{"error" => "not mocked"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      Req.Test.allow(ManagedIdentity, self(), lv.pid)
      Req.Test.allow(APIClient, self(), lv.pid)
      Req.Test.allow(PortalWeb.OIDC, self(), lv.pid)

      expect_google_directory_service_access("C0123", "example.com")

      assert has_element?(lv, "#verify-button-open-url[phx-hook='OpenURL']")

      assert has_element?(
               lv,
               "button[phx-click='start_verification'][data-open-url-reserve]"
             )

      lv
      |> element("button[phx-click='start_verification']")
      |> render_click()

      assert_push_event(lv, "open_url", %{url: url})
      assert URI.parse(url).host == "mock.oidc.test"
      assert has_element?(lv, "#verify-button-open-url[phx-hook='OpenURL']")
      assert has_element?(lv, "#verify-button-open-url button[disabled]", "Verifying...")
    end

    test "requires reverification after regenerating an okta keypair", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory =
        okta_directory_fixture(%{
          account: account,
          name: "Okta Key Rotation",
          okta_domain: "key-rotation.okta.com",
          is_verified: true
        })

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      assert html =~ "This directory has been successfully verified."
      refute html =~ "Verify Now"

      html = render_click(lv, "generate_keypair")

      assert html =~ "Verify Now"
      assert html =~ "Awaiting verification..."
      refute html =~ "This directory has been successfully verified."
      assert has_element?(lv, "button[form='directory-form'][disabled]", "Save")
    end

    test "updates a google directory name", %{conn: conn, account: account, actor: actor} do
      directory =
        google_directory_fixture(%{
          account: account,
          name: "Old Google Directory",
          domain: "old.example.com",
          impersonation_email: "admin@old.example.com",
          is_verified: true
        })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      form =
        form(lv, "#directory-form",
          directory: %{
            name: "Updated Google Directory",
            impersonation_email: "admin@old.example.com"
          }
        )

      render_change(form)
      html = render_submit(form)

      assert html =~ "Directory saved successfully."
      assert_patch(lv, ~p"/#{account}/settings/directory_sync")

      assert %Portal.Google.Directory{name: "Updated Google Directory"} =
               Repo.get!(Portal.Google.Directory, directory.id)
    end
  end
end
