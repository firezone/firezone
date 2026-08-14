defmodule PortalWeb.Settings.DeviceIntegrationsTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.ActorFixtures
  import Portal.IntuneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  defp reload(integration) do
    Portal.Repo.get_by!(Portal.Intune.Integration,
      account_id: integration.account_id,
      id: integration.id
    )
  end

  defp reverify(lv, tenant_id) do
    if has_element?(lv, "button[phx-click=reset_verification]") do
      lv |> element("button[phx-click=reset_verification]") |> render_click()
    end

    lv |> element("#intune-admin-consent-button") |> render_click()
    assert_push_event(lv, "open_url", %{url: url})

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

    # The OIDC controller consumes the pending verifier before the callback
    # completes, which is what promotes it to the active verification.
    send(lv.pid, {:get_pending_verification, self()})
    assert_receive {:pending_verification, %{verification_ref: ^ref}}

    ack_ref = make_ref()

    send(lv.pid, {:intune_device_integration_complete, tenant_id, ref, {self(), ack_ref}})
    assert_receive {:verification_ack, ^ack_ref}

    lv
  end

  describe "device_posture feature gate" do
    test "hides the settings tab when the global flag is off", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_device_posture(false)

      {:ok, _lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/directory_sync")

      refute html =~ "settings/device_integrations"
    end

    test "shows the settings tab when the global flag is on", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "settings/device_integrations"
      assert html =~ "Device Posture"
    end

    test "redirects away from the page when the global flag is off", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_device_posture(false)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      assert to =~ "/settings/account"
    end

    test "shows the upgrade splash when the account lacks the feature", %{conn: conn} do
      account = Portal.AccountFixtures.account_fixture()
      actor = Portal.ActorFixtures.admin_actor_fixture(account: account)

      {:ok, lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      assert html =~ "Upgrade to Unlock"
      assert html =~ "Inventory Your Managed Devices"
      refute html =~ "Add Device Integration"

      # The slide-over cannot be opened from the splash.
      assert lv
             |> render_patch(~p"/#{account}/settings/device_integrations/intune/new")
             |> Kernel.=~("Upgrade to Unlock")
    end

    test "refuses to write when the feature is switched off mid-session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      integration = intune_integration_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      enable_device_posture(false)

      render_click(lv, "toggle", %{"id" => integration.id})

      refute Portal.Repo.get_by!(Portal.Intune.Integration,
               account_id: integration.account_id,
               id: integration.id
             ).is_disabled
    end
  end

  test "renders the empty integration settings page", %{conn: conn, account: account, actor: actor} do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_integrations")

    assert html =~ "Device Integrations"
    assert html =~ "No device integrations configured."
    assert html =~ "Add a device integration"
    refute html =~ "Devices synced"
  end

  test "summarises synced devices by compliance state", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    integration = intune_integration_fixture(account: account)

    for state <- ~w[compliant compliant noncompliant inGracePeriod unknown] do
      intune_device_fixture(integration: integration, compliance_state: state)
    end

    intune_device_fixture(compliance_state: "compliant")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_integrations")

    summary = lv |> element("#device-integration-summary") |> render()

    assert summary =~ "Devices synced"
    assert summary =~ ~r/5.*Devices synced/s
    assert summary =~ ~r/2.*Compliant/s
    assert summary =~ ~r/1.*Not compliant/s
    assert summary =~ ~r/1.*In grace period/s
  end

  test "uses the signed Microsoft consent flow and creates the verified integration", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_integrations/intune/new")

    assert has_element?(
             lv,
             "#intune-admin-consent-button[phx-click=start_verification][phx-hook=OpenURL]"
           )

    lv |> element("#intune-admin-consent-button") |> render_click()
    assert_push_event(lv, "open_url", %{url: url})

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    assert {:ok,
            %{
              type: "intune-device-integration",
              verification_ref: verification_ref
            }} = PortalWeb.OIDC.verify_verification_state(state)

    send(lv.pid, {:get_pending_verification, self()})
    assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}

    ack_ref = make_ref()

    send(
      lv.pid,
      {:intune_device_integration_complete, "tenant-123", verification_ref, {self(), ack_ref}}
    )

    assert_receive {:verification_ack, ^ack_ref}
    assert render(lv) =~ "tenant-123"

    lv
    |> form("#device-integration-form", integration: %{name: "Corporate Intune"})
    |> render_submit()

    assert_patch(lv, ~p"/#{account}/settings/device_integrations")

    integration = Portal.Repo.get_by!(Portal.Intune.Integration, account_id: account.id)
    assert integration.name == "Corporate Intune"
    assert integration.tenant_id == "tenant-123"
    assert integration.is_verified
  end

  describe "sync action" do
    test "queues a sync for an integration in the caller's account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      integration = intune_integration_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      render_click(lv, "sync", %{"id" => integration.id})

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{"account_id" => integration.account_id, "device_integration_id" => integration.id}
      )
    end

    test "refuses to queue a sync for another account's integration", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_device_posture()
      other_account = device_posture_account_fixture()
      other_integration = intune_integration_fixture(account: other_account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      render_click(lv, "sync", %{"id" => other_integration.id})

      refute_enqueued(
        worker: Portal.Intune.Sync,
        args: %{
          "account_id" => other_integration.account_id,
          "device_integration_id" => other_integration.id
        }
      )

      refute_enqueued(worker: Portal.Intune.Sync)
    end

    test "refuses to queue a sync when the feature is switched off mid-session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      integration = intune_integration_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      enable_device_posture(false)

      render_click(lv, "sync", %{"id" => integration.id})

      refute_enqueued(
        worker: Portal.Intune.Sync,
        args: %{"account_id" => integration.account_id, "device_integration_id" => integration.id}
      )
    end
  end

  describe "recovering from a sync error" do
    setup %{account: account} do
      integration =
        intune_integration_fixture(
          account: account,
          is_disabled: true,
          is_verified: false,
          disabled_reason: "Sync error",
          error_message: "403 - Forbidden",
          errored_at: DateTime.utc_now(),
          error_email_count: 2
        )

      %{integration: integration}
    end

    test "refuses to enable an integration that is not verified", %{
      conn: conn,
      account: account,
      actor: actor,
      integration: integration
    } do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      assert render_click(lv, "toggle", %{"id" => integration.id}) =~
               "must be verified before enabling"

      assert reload(integration).is_disabled
    end

    test "clears the error state when a verified integration is enabled", %{
      conn: conn,
      account: account,
      actor: actor,
      integration: integration
    } do
      integration
      |> Ecto.Changeset.change(is_verified: true)
      |> Portal.Repo.update!()

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_integrations")

      render_click(lv, "toggle", %{"id" => integration.id})

      integration = reload(integration)
      refute integration.is_disabled
      refute integration.disabled_reason
      refute integration.error_message
      refute integration.errored_at
      assert integration.error_email_count == 0
    end
  end

  describe "reverifying after a sync error" do
    setup %{conn: conn, account: account, actor: actor} do
      integration =
        intune_integration_fixture(
          account: account,
          is_disabled: true,
          is_verified: false,
          disabled_reason: "Sync error",
          error_message: "403 - Forbidden",
          errored_at: DateTime.utc_now(),
          error_email_count: 2
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_integrations/intune/#{integration.id}/edit")

      %{integration: integration, lv: lv}
    end

    test "enables the integration and clears the error state", %{
      lv: lv,
      integration: integration
    } do
      reverify(lv, "tenant-123")

      lv
      |> form("#device-integration-form", integration: %{name: integration.name})
      |> render_submit()

      integration = reload(integration)
      assert integration.is_verified
      refute integration.is_disabled
      refute integration.disabled_reason
      refute integration.error_message
      refute integration.errored_at
      assert integration.error_email_count == 0
    end

    test "queues a sync so the stale inventory is refreshed", %{
      lv: lv,
      integration: integration
    } do
      reverify(lv, integration.tenant_id)

      lv
      |> form("#device-integration-form", integration: %{name: integration.name})
      |> render_submit()

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{
          "account_id" => integration.account_id,
          "device_integration_id" => integration.id
        }
      )
    end
  end

  test "reverifying does not re-enable an integration an admin disabled", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    integration =
      intune_integration_fixture(
        account: account,
        is_disabled: true,
        is_verified: false,
        disabled_reason: "Disabled by admin"
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_integrations/intune/#{integration.id}/edit")

    reverify(lv, "tenant-123")

    lv
    |> form("#device-integration-form", integration: %{name: integration.name})
    |> render_submit()

    integration = reload(integration)
    assert integration.is_verified
    assert integration.is_disabled
    assert integration.disabled_reason == "Disabled by admin"
  end

  describe "editing an integration" do
    test "queues a sync when the verified tenant changes", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      integration = intune_integration_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_integrations/intune/#{integration.id}/edit")

      lv |> element("button[phx-click=reset_verification]") |> render_click()
      lv |> element("#intune-admin-consent-button") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
      {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

      send(lv.pid, {:get_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^ref}}

      ack_ref = make_ref()

      send(lv.pid, {:intune_device_integration_complete, "new-tenant", ref, {self(), ack_ref}})
      assert_receive {:verification_ack, ^ack_ref}

      lv
      |> form("#device-integration-form", integration: %{name: integration.name})
      |> render_submit()

      assert reload(integration).tenant_id == "new-tenant"

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{
          "account_id" => integration.account_id,
          "device_integration_id" => integration.id
        }
      )
    end

    test "does not queue a sync when the tenant is unchanged", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      integration = intune_integration_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_integrations/intune/#{integration.id}/edit")

      lv
      |> form("#device-integration-form", integration: %{name: "Renamed"})
      |> render_submit()

      assert reload(integration).name == "Renamed"
      refute_enqueued(worker: Portal.Intune.Sync)
    end
  end

  test "returns a changeset error when a second integration races the first", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_integrations/intune/new")

    lv |> element("#intune-admin-consent-button") |> render_click()
    assert_push_event(lv, "open_url", %{url: url})

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    {:ok, %{verification_ref: verification_ref}} = PortalWeb.OIDC.verify_verification_state(state)

    send(lv.pid, {:get_pending_verification, self()})
    assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}

    ack_ref = make_ref()

    send(
      lv.pid,
      {:intune_device_integration_complete, "tenant-123", verification_ref, {self(), ack_ref}}
    )

    assert_receive {:verification_ack, ^ack_ref}

    # The page decided the account had none while this was open.
    intune_integration_fixture(account: account)

    html =
      lv
      |> form("#device-integration-form", integration: %{name: "Corporate Intune"})
      |> render_submit()

    assert html =~ "device-integration-form"
    assert Portal.Repo.aggregate(Portal.DeviceIntegration, :count) == 1
  end

  test "allows only one configured inventory provider", %{conn: conn, account: account, actor: actor} do
    intune_integration_fixture(account: account)

    assert {:error,
            {:live_redirect,
             %{
               to: path,
               flash: %{"error" => "Only one device inventory integration can be configured at a time."}
             }}} =
             conn
             |> authorize_conn(actor)
             |> live(~p"/#{account}/settings/device_integrations/intune/new")

    assert path == ~p"/#{account}/settings/device_integrations"
  end
end
