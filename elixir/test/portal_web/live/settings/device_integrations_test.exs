defmodule PortalWeb.Settings.DeviceIntegrationsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.IntuneFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "renders the empty integration settings page", %{conn: conn, account: account, actor: actor} do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_integrations")

    assert html =~ "Device Inventory"
    assert html =~ "No device inventory integration configured."
    assert html =~ "Add Device Integration"
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
