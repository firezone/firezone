defmodule PortalWeb.Settings.DirectorySyncTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.OktaDirectoryFixtures

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

    assert {:ok, %{verification_ref: verification_ref}} =
             PortalWeb.OIDC.verify_verification_state(state)

    verification_ref
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

      html = render_click(lv, "sync_directory", %{"id" => directory.id, "type" => "google"})
      assert html =~ "Directory sync has been queued successfully."

      html = render_click(lv, "delete_directory", %{"id" => directory.id})
      assert html =~ "Directory deleted successfully."
      refute html =~ "Ops Google"
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

    test "ignores stale entra directory verification after reset", %{
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

      render_click(lv, "reset_verification")

      ack_ref = make_ref()

      send(
        lv.pid,
        {:entra_directory_sync_complete, "stale-tenant", verification_ref, {self(), ack_ref}}
      )

      assert_receive {:verification_ack, ^ack_ref}

      html = render(lv)
      refute html =~ "Verified"
      refute html =~ "stale-tenant"
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
