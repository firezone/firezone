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
        args: %{"device_integration_id" => integration.id}
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

      Process.flag(:trap_exit, true)
      catch_exit(render_click(lv, "sync", %{"id" => other_integration.id}))

      refute_enqueued(
        worker: Portal.Intune.Sync,
        args: %{"device_integration_id" => other_integration.id}
      )
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
        args: %{"device_integration_id" => integration.id}
      )
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
