defmodule PortalWeb.Settings.DevicePostureTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures
  import Portal.IruFixtures
  import Portal.DefenderFixtures
  import Portal.SantaFixtures
  import Portal.SentinelOneFixtures

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  defp reload(provider) do
    provider.__struct__
    |> Portal.Repo.get_by!(account_id: provider.account_id, id: provider.id)
    |> Map.put(:name, provider_name(provider))
  end

  # The name lives on the shared posture_providers row.
  defp provider_name(provider) do
    Portal.Repo.get_by!(Portal.PostureProvider,
      account_id: provider.account_id,
      id: provider.id
    ).name
  end

  defp reverify(lv, tenant_id) do
    if has_element?(lv, "button[phx-click=reset_verification]") do
      lv |> element("button[phx-click=reset_verification]") |> render_click()
    end

    lv |> element("#provider-verification-button") |> render_click()
    assert_push_event(lv, "open_url", %{url: url})

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

    # The OIDC controller consumes the pending verifier before the callback
    # completes, which is what promotes it to the active verification.
    send(lv.pid, {:get_pending_verification, self()})
    assert_receive {:pending_verification, %{verification_ref: ^ref}}

    ack_ref = make_ref()

    send(lv.pid, {:intune_posture_provider_complete, tenant_id, ref, {self(), ack_ref}})
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

      refute html =~ "settings/device_posture"
    end

    test "shows the settings tab when the global flag is on even without the account feature", %{
      conn: conn
    } do
      account = Portal.AccountFixtures.account_fixture(features: %{device_posture: false})
      actor = Portal.ActorFixtures.admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "settings/device_posture"
      assert html =~ "Device Posture"
    end

    test "redirects away from the page when the global flag is off", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_device_posture(false)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      assert to =~ "/settings/account"
    end

    test "shows the upgrade splash when the account lacks the feature", %{conn: conn} do
      account = Portal.AccountFixtures.account_fixture()
      actor = Portal.ActorFixtures.admin_actor_fixture(account: account)

      {:ok, lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      assert html =~ "Upgrade to Unlock"
      assert html =~ "Inventory Your Managed Devices"
      assert html =~
               "Integrate with MDM and EDR solutions to provide device telemetry to use in policy conditions"

      assert html =~ "settings/device_posture"
      refute html =~ "Add posture provider"

      # The slide-over cannot be opened from the splash.
      assert lv
             |> render_patch(~p"/#{account}/settings/device_posture/intune/new")
             |> Kernel.=~("Upgrade to Unlock")
    end

    test "refuses to write when the feature is switched off mid-session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      enable_device_posture(false)

      render_click(lv, "toggle", %{"id" => provider.id})

      refute Portal.Repo.get_by!(Portal.Intune.PostureProvider,
               account_id: provider.account_id,
               id: provider.id
             ).is_disabled
    end
  end

  test "renders the empty provider settings page", %{conn: conn, account: account, actor: actor} do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture")

    assert html =~ "Device Posture"
    assert html =~ "No posture provider configured."
    assert html =~ "Add posture provider"
    refute html =~ "Devices synced"
    refute html =~ "Upgrade to Unlock"
  end

  test "summarises synced devices by compliance state", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    provider = intune_posture_provider_fixture(account: account)

    for state <- ~w[compliant compliant noncompliant inGracePeriod unknown] do
      intune_device_fixture(provider: provider, compliance_state: state)
    end

    intune_device_fixture(compliance_state: "compliant")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture")

    summary = lv |> element("#device-posture-summary") |> render()

    assert summary =~ "Devices synced"
    assert summary =~ ~r/5.*Devices synced/s
    assert summary =~ ~r/2.*Compliant/s
    assert summary =~ ~r/1.*Not compliant/s
    assert summary =~ ~r/1.*In grace period/s
  end

  test "uses the signed Microsoft consent flow and creates the verified provider", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/intune/new")

    assert has_element?(
             lv,
             "#provider-verification.p-4.border.border-border.bg-raised.rounded"
           )
    assert has_element?(lv, "#provider-verification-open-url[phx-hook=OpenURL]")

    assert has_element?(
             lv,
             "#provider-verification-button[phx-click=start_verification]",
             "Verify Now"
           )

    assert has_element?(lv, "#provider-tenant-id", "Awaiting verification...")

    lv |> element("#provider-verification-button") |> render_click()
    assert_push_event(lv, "open_url", %{url: url})
    assert has_element?(lv, "#provider-verification-open-url button[disabled]", "Verifying...")

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    assert {:ok,
            %{
              type: "intune-posture-provider",
              verification_ref: verification_ref
            }} = PortalWeb.OIDC.verify_verification_state(state)

    send(lv.pid, {:get_pending_verification, self()})
    assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}

    ack_ref = make_ref()

    send(
      lv.pid,
      {:intune_posture_provider_complete, "tenant-123", verification_ref, {self(), ack_ref}}
    )

    assert_receive {:verification_ack, ^ack_ref}
    assert render(lv) =~ "tenant-123"
    assert has_element?(lv, "#provider-verification-status", "Verified")
    assert has_element?(lv, "#provider-tenant-id", "tenant-123")
    assert has_element?(lv, "button[phx-click=reset_verification]", "Reset verification")

    lv
    |> form("#device-posture-form", provider: %{name: "Corporate Intune"})
    |> render_submit()

    assert_patch(lv, ~p"/#{account}/settings/device_posture")

    provider = Portal.Repo.get_by!(Portal.Intune.PostureProvider, account_id: account.id)
    assert provider_name(provider) == "Corporate Intune"
    assert provider.tenant_id == "tenant-123"
    assert provider.is_verified
  end

  describe "sync action" do
    test "queues a sync for a provider in the caller's account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      render_click(lv, "sync", %{"id" => provider.id})

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      )
    end

    test "refuses to queue a sync for another account's provider", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_device_posture()
      other_account = device_posture_account_fixture()
      other_provider = intune_posture_provider_fixture(account: other_account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      render_click(lv, "sync", %{"id" => other_provider.id})

      refute_enqueued(
        worker: Portal.Intune.Sync,
        args: %{
          "account_id" => other_provider.account_id,
          "posture_provider_id" => other_provider.id
        }
      )

      refute_enqueued(worker: Portal.Intune.Sync)
    end

    test "refuses to queue a sync when the feature is switched off mid-session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      enable_device_posture(false)

      render_click(lv, "sync", %{"id" => provider.id})

      refute_enqueued(
        worker: Portal.Intune.Sync,
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      )
    end
  end

  describe "recovering from a sync error" do
    setup %{account: account} do
      provider =
        intune_posture_provider_fixture(
          account: account,
          is_disabled: true,
          is_verified: false,
          disabled_reason: "Sync error",
          error_message: "403 - Forbidden",
          errored_at: DateTime.utc_now(),
          error_email_count: 2
        )

      %{provider: provider}
    end

    test "refuses to enable a provider that is not verified", %{
      conn: conn,
      account: account,
      actor: actor,
      provider: provider
    } do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      assert render_click(lv, "toggle", %{"id" => provider.id}) =~
               "must be verified before enabling"

      assert reload(provider).is_disabled
    end

    test "clears the error state when a verified provider is enabled", %{
      conn: conn,
      account: account,
      actor: actor,
      provider: provider
    } do
      provider
      |> Ecto.Changeset.change(is_verified: true)
      |> Portal.Repo.update!()

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      render_click(lv, "toggle", %{"id" => provider.id})

      provider = reload(provider)
      refute provider.is_disabled
      refute provider.disabled_reason
      refute provider.error_message
      refute provider.errored_at
      assert provider.error_email_count == 0
    end
  end

  describe "stale socket state" do
    test "refuses writes after the account is downgraded mid-session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

      # The socket keeps the account it mounted with, so the downgrade is only
      # visible to a write path that re-reads it.
      account
      |> Ecto.Changeset.change(features: %Portal.Accounts.Features{device_posture: false})
      |> Portal.Repo.update!()

      render_click(lv, "toggle", %{"id" => provider.id})

      refute reload(provider).is_disabled
    end

    test "survives a verification that lands after the panel closed", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/intune/new")

      lv |> element("#provider-verification-button") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
      {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

      render_patch(lv, ~p"/#{account}/settings/device_posture")

      # The callback consumes the pending verifier only if it outlived the panel.
      send(lv.pid, {:get_pending_verification, self()})
      assert_receive {:pending_verification, nil}

      ack_ref = make_ref()
      send(lv.pid, {:intune_posture_provider_complete, "tenant-123", ref, {self(), ack_ref}})
      assert_receive {:verification_ack, ^ack_ref}

      assert render(lv) =~ "Device Posture"
    end
  end

  describe "reverifying after a sync error" do
    setup %{conn: conn, account: account, actor: actor} do
      provider =
        intune_posture_provider_fixture(
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
        |> live(~p"/#{account}/settings/device_posture/intune/#{provider.id}/edit")

      %{provider: provider, lv: lv}
    end

    test "enables the provider and clears the error state", %{
      lv: lv,
      provider: provider
    } do
      reverify(lv, "tenant-123")

      lv
      |> form("#device-posture-form", provider: %{name: provider.name})
      |> render_submit()

      provider = reload(provider)
      assert provider.is_verified
      refute provider.is_disabled
      refute provider.disabled_reason
      refute provider.error_message
      refute provider.errored_at
      assert provider.error_email_count == 0
    end

    test "queues a sync so the stale inventory is refreshed", %{
      lv: lv,
      provider: provider
    } do
      reverify(lv, provider.tenant_id)

      lv
      |> form("#device-posture-form", provider: %{name: provider.name})
      |> render_submit()

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{
          "account_id" => provider.account_id,
          "posture_provider_id" => provider.id
        }
      )
    end
  end

  test "reverifying does not re-enable a provider an admin disabled", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    provider =
      intune_posture_provider_fixture(
        account: account,
        is_disabled: true,
        is_verified: false,
        disabled_reason: "Disabled by admin"
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/intune/#{provider.id}/edit")

    reverify(lv, "tenant-123")

    lv
    |> form("#device-posture-form", provider: %{name: provider.name})
    |> render_submit()

    provider = reload(provider)
    assert provider.is_verified
    assert provider.is_disabled
    assert provider.disabled_reason == "Disabled by admin"
  end

  describe "editing a provider" do
    test "queues a sync when the verified tenant changes", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/intune/#{provider.id}/edit")

      lv |> element("button[phx-click=reset_verification]") |> render_click()
      lv |> element("#provider-verification-button") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
      {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

      send(lv.pid, {:get_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^ref}}

      ack_ref = make_ref()

      send(lv.pid, {:intune_posture_provider_complete, "new-tenant", ref, {self(), ack_ref}})
      assert_receive {:verification_ack, ^ack_ref}

      lv
      |> form("#device-posture-form", provider: %{name: provider.name})
      |> render_submit()

      assert reload(provider).tenant_id == "new-tenant"

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{
          "account_id" => provider.account_id,
          "posture_provider_id" => provider.id
        }
      )
    end

    test "does not queue a sync when the tenant is unchanged", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      provider = intune_posture_provider_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/intune/#{provider.id}/edit")

      lv
      |> form("#device-posture-form", provider: %{name: "Renamed"})
      |> render_submit()

      assert reload(provider).name == "Renamed"
      refute_enqueued(worker: Portal.Intune.Sync)
    end
  end

  test "surfaces a changeset error when the tenant is already connected", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/intune/new")

    reverify(lv, "tenant-123")

    # Another admin connected the same tenant while this panel was open.
    intune_posture_provider_fixture(account: account, tenant_id: "tenant-123")

    html =
      lv
      |> form("#device-posture-form", provider: %{name: "Corporate Intune"})
      |> render_submit()

    assert html =~ "This Intune tenant is already connected."
    assert Portal.Repo.aggregate(Portal.PostureProvider, :count) == 1
  end

  test "refuses a name another provider of the account already uses", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    iru_posture_provider_fixture(account: account, name: "Corporate")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/intune/new")

    reverify(lv, "tenant-123")

    html =
      lv
      |> form("#device-posture-form", provider: %{name: "Corporate"})
      |> render_submit()

    assert html =~ "A posture provider with this name already exists."
    assert Portal.Repo.aggregate(Portal.PostureProvider, :count) == 1
  end

  test "refuses to rename a provider onto a name already in use", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    iru_posture_provider_fixture(account: account, name: "Corporate")
    provider = intune_posture_provider_fixture(account: account, name: "Contoso")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/intune/#{provider.id}/edit")

    html =
      lv
      |> form("#device-posture-form", provider: %{name: "Corporate"})
      |> render_submit()

    assert html =~ "A posture provider with this name already exists."
    assert provider_name(provider) == "Contoso"
  end

  test "connects a second provider of the same type", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    intune_posture_provider_fixture(account: account, tenant_id: "first-tenant")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/intune/new")

    reverify(lv, "second-tenant")

    lv
    |> form("#device-posture-form", provider: %{name: "Second Intune"})
    |> render_submit()

    assert_patch(lv, ~p"/#{account}/settings/device_posture")
    assert Portal.Repo.aggregate(Portal.PostureProvider, :count) == 2
  end

  describe "selecting a provider type" do
    test "lists every provider type", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture/new")

      html = render(lv)
      assert html =~ "Select Provider Type"
      assert html =~ "Microsoft Intune"
      assert html =~ "Iru"
      assert html =~ "Microsoft Defender for Endpoint"
      assert html =~ "Santa"
      assert html =~ "SentinelOne"

      assert has_element?(
               lv,
               ~s|a[href="/#{account.slug}/settings/device_posture/intune/new"]|
             )

      assert has_element?(lv, ~s|a[href="/#{account.slug}/settings/device_posture/iru/new"]|)

      assert has_element?(
               lv,
               ~s|a[href="/#{account.slug}/settings/device_posture/defender/new"]|
             )
      assert has_element?(lv, ~s|a[href="/#{account.slug}/settings/device_posture/santa/new"]|)

      assert has_element?(
               lv,
               ~s|a[href="/#{account.slug}/settings/device_posture/sentinelone/new"]|
             )
    end

    test "raises on an unknown provider type", %{conn: conn, account: account, actor: actor} do
      assert_raise PortalWeb.LiveErrors.NotFoundError, fn ->
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture/jamf/new")
      end
    end
  end

  describe "SentinelOne providers" do
    setup %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/sentinelone/new")

      %{lv: lv}
    end

    test "verifies endpoint access and creates the provider", %{lv: lv, account: account} do
      Req.Test.stub(Portal.SentinelOne.APIClient, fn conn ->
        Req.Test.json(conn, %{"data" => [], "pagination" => %{"nextCursor" => nil}})
      end)

      Req.Test.allow(Portal.SentinelOne.APIClient, self(), lv.pid)

      html = render(lv)
      assert html =~ "GET /web/api/v2.1/agents"
      assert html =~ "logo-sentinelone.svg"

      attrs = %{
        name: "Production S1",
        management_url: "Tenant-US1.SentinelOne.net/dashboard/agents",
        api_token: "token"
      }

      lv |> form("#device-posture-form", provider: attrs) |> render_change()
      lv |> element("#provider-verification-button") |> render_click()
      assert has_element?(lv, "#provider-verification-status", "Verified")

      lv |> form("#device-posture-form", provider: attrs) |> render_submit()
      assert_patch(lv, ~p"/#{account}/settings/device_posture")

      provider =
        Portal.Repo.get_by!(Portal.SentinelOne.PostureProvider, account_id: account.id)

      assert provider_name(provider) == "Production S1"
      assert provider.management_url == "https://tenant-us1.sentinelone.net"
      assert provider.api_token == "token"
      assert provider.is_verified

      assert_enqueued(
        worker: Portal.SentinelOne.Sync,
        args: %{"account_id" => account.id, "posture_provider_id" => provider.id}
      )
    end

    test "reports a rejected token and saves nothing", %{lv: lv} do
      Req.Test.stub(Portal.SentinelOne.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"errors" => [%{"title" => "Unauthorized"}]})
      end)

      Req.Test.allow(Portal.SentinelOne.APIClient, self(), lv.pid)

      lv
      |> form("#device-posture-form",
        provider: %{
          name: "Production S1",
          management_url: "https://tenant.sentinelone.net",
          api_token: "wrong"
        }
      )
      |> render_change()

      lv |> element("#provider-verification-button") |> render_click()

      assert render(lv) =~ "SentinelOne rejected the API token"
      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert Portal.Repo.aggregate(Portal.SentinelOne.PostureProvider, :count) == 0
    end
  end

  describe "Santa providers" do
    setup %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture/santa/new")

      %{lv: lv}
    end

    test "verifies ListHosts and creates the provider", %{lv: lv, account: account} do
      parent = self()

      Req.Test.stub(Portal.Santa.APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:santa_request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"hosts" => [], "more" => false})
      end)

      Req.Test.allow(Portal.Santa.APIClient, self(), lv.pid)

      attrs = %{
        name: "Acme Santa",
        api_url: "acme.workshop.cloud/api/explorer",
        api_key: "npsws_sk_secret"
      }

      lv |> form("#device-posture-form", provider: attrs) |> render_change()
      lv |> element("#provider-verification-button") |> render_click()

      assert has_element?(lv, "#provider-verification-status", "Verified")
      assert_received {:santa_request, "/workshop.v1.WorkshopService/ListHosts", ["npsws_sk_secret"]}

      lv |> form("#device-posture-form", provider: attrs) |> render_submit()
      assert_patch(lv, ~p"/#{account}/settings/device_posture")

      provider = Portal.Repo.get_by!(Portal.Santa.PostureProvider, account_id: account.id)
      assert provider_name(provider) == "Acme Santa"
      assert provider.api_url == "https://acme.workshop.cloud"
      assert provider.api_key == "npsws_sk_secret"
      assert provider.is_verified

      assert_enqueued(
        worker: Portal.Santa.Sync,
        args: %{"account_id" => account.id, "posture_provider_id" => provider.id}
      )
    end

    test "reports a rejected API key and saves nothing", %{lv: lv} do
      Req.Test.stub(Portal.Santa.APIClient, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "invalid key"})
      end)

      Req.Test.allow(Portal.Santa.APIClient, self(), lv.pid)

      lv
      |> form("#device-posture-form",
        provider: %{
          name: "Acme Santa",
          api_url: "https://acme.workshop.cloud",
          api_key: "npsws_sk_wrong"
        }
      )
      |> render_change()

      lv |> element("#provider-verification-button") |> render_click()

      assert render(lv) =~ "Workshop rejected the API key"
      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert Portal.Repo.aggregate(Portal.Santa.PostureProvider, :count) == 0
    end

    test "drops verification when the Workshop tenant changes", %{lv: lv} do
      Req.Test.stub(Portal.Santa.APIClient, fn conn ->
        Req.Test.json(conn, %{"hosts" => [], "more" => false})
      end)

      Req.Test.allow(Portal.Santa.APIClient, self(), lv.pid)

      attrs = %{
        name: "Acme Santa",
        api_url: "https://acme.workshop.cloud",
        api_key: "npsws_sk_secret"
      }

      lv |> form("#device-posture-form", provider: attrs) |> render_change()
      lv |> element("#provider-verification-button") |> render_click()
      assert has_element?(lv, "#provider-verification-status", "Verified")

      lv
      |> form("#device-posture-form",
        provider: %{attrs | api_url: "https://other.workshop.cloud"}
      )
      |> render_change()

      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert has_element?(lv, "#provider-verification-button", "Verify Now")
    end

    test "rejects a changed Workshop tenant submitted before its debounce fires", %{lv: lv} do
      Req.Test.stub(Portal.Santa.APIClient, fn conn ->
        Req.Test.json(conn, %{"hosts" => [], "more" => false})
      end)

      Req.Test.allow(Portal.Santa.APIClient, self(), lv.pid)

      attrs = %{
        name: "Acme Santa",
        api_url: "https://acme.workshop.cloud",
        api_key: "npsws_sk_secret"
      }

      lv |> form("#device-posture-form", provider: attrs) |> render_change()
      lv |> element("#provider-verification-button") |> render_click()
      assert has_element?(lv, "#provider-verification-status", "Verified")

      render_submit(lv, "submit", %{
        "provider" => %{
          "name" => attrs.name,
          "api_url" => "https://other.workshop.cloud",
          "api_key" => attrs.api_key
        }
      })

      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert Portal.Repo.aggregate(Portal.Santa.PostureProvider, :count) == 0
    end
  end

  describe "Iru providers" do
    setup %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture/iru/new")

      %{lv: lv}
    end

    test "names every endpoint the token has to allow", %{lv: lv} do
      html = render(lv)

      assert html =~ "GET /api/v1/devices"

      for category <- Portal.Iru.Sync.prism_categories() do
        assert html =~ "GET /api/v1/prism/#{category}"
      end

      assert html =~ "An endpoint you leave off is skipped"
    end

    test "verifies the token against the tenant and creates the provider", %{
      lv: lv,
      account: account
    } do
      Req.Test.stub(Portal.Iru.APIClient, fn conn -> Req.Test.json(conn, []) end)
      Req.Test.allow(Portal.Iru.APIClient, self(), lv.pid)

      lv
      |> form("#device-posture-form",
        provider: %{name: "Acme Iru", subdomain: "acme", region: "us", api_token: "token"}
      )
      |> render_change()

      lv |> element("#provider-verification-button") |> render_click()
      assert has_element?(lv, "#provider-verification-status", "Verified")

      lv
      |> form("#device-posture-form",
        provider: %{name: "Acme Iru", subdomain: "acme", region: "us", api_token: "token"}
      )
      |> render_submit()

      assert_patch(lv, ~p"/#{account}/settings/device_posture")

      provider = Portal.Repo.get_by!(Portal.Iru.PostureProvider, account_id: account.id)
      assert provider_name(provider) == "Acme Iru"
      assert provider.subdomain == "acme"
      assert provider.region == :us
      assert provider.api_token == "token"
      assert provider.is_verified

      assert_enqueued(
        worker: Portal.Iru.Sync,
        args: %{"account_id" => account.id, "posture_provider_id" => provider.id}
      )
    end

    test "reports a rejected token and saves nothing", %{lv: lv} do
      Req.Test.stub(Portal.Iru.APIClient, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"detail" => "Invalid token."})
      end)

      Req.Test.allow(Portal.Iru.APIClient, self(), lv.pid)

      lv
      |> form("#device-posture-form",
        provider: %{name: "Acme Iru", subdomain: "acme", region: "us", api_token: "wrong"}
      )
      |> render_change()

      lv |> element("#provider-verification-button") |> render_click()

      assert render(lv) =~ "Iru rejected the API token"
      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert Portal.Repo.aggregate(Portal.Iru.PostureProvider, :count) == 0
    end

    test "keeps a pasted token when another field triggers validation", %{lv: lv} do
      render_hook(lv, "validate", %{
        "provider" => %{"api_token" => "pasted-token"}
      })

      html =
        render_hook(lv, "validate", %{
          "provider" => %{"name" => "Acme Iru"}
        })

      assert html =~ ~s(value="pasted-token")
    end

    test "drops the verification when the tenant changes", %{lv: lv} do
      Req.Test.stub(Portal.Iru.APIClient, fn conn -> Req.Test.json(conn, []) end)
      Req.Test.allow(Portal.Iru.APIClient, self(), lv.pid)

      lv
      |> form("#device-posture-form",
        provider: %{name: "Acme Iru", subdomain: "acme", region: "us", api_token: "token"}
      )
      |> render_change()

      lv |> element("#provider-verification-button") |> render_click()
      assert has_element?(lv, "#provider-verification-status", "Verified")

      lv
      |> form("#device-posture-form",
        provider: %{name: "Acme Iru", subdomain: "other", region: "us", api_token: "token"}
      )
      |> render_change()

      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert has_element?(lv, "#provider-verification-button", "Verify Now")
    end

    test "rejects a changed tenant submitted before its debounce fires", %{lv: lv} do
      Req.Test.stub(Portal.Iru.APIClient, fn conn -> Req.Test.json(conn, []) end)
      Req.Test.allow(Portal.Iru.APIClient, self(), lv.pid)

      attrs = %{name: "Acme Iru", subdomain: "acme", region: "us", api_token: "token"}

      lv |> form("#device-posture-form", provider: attrs) |> render_change()
      lv |> element("#provider-verification-button") |> render_click()
      assert has_element?(lv, "#provider-verification-status", "Verified")

      render_submit(lv, "submit", %{
        "provider" => %{
          "name" => attrs.name,
          "subdomain" => "other",
          "region" => attrs.region,
          "api_token" => attrs.api_token
        }
      })

      refute has_element?(lv, "#provider-verification-status", "Verified")
      assert Portal.Repo.aggregate(Portal.Iru.PostureProvider, :count) == 0
    end
  end

  test "renaming an Iru provider keeps the stored API token", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    provider = iru_posture_provider_fixture(account: account, api_token: "secret-token")

    {:ok, lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/iru/#{provider.id}/edit")

    refute html =~ "secret-token"

    lv
    |> form("#device-posture-form", provider: %{name: "Renamed Iru", api_token: ""})
    |> render_submit()



    assert_patch(lv, ~p"/#{account}/settings/device_posture")

    reloaded = reload(provider)

    assert reloaded.name == "Renamed Iru"
    assert reloaded.api_token == "secret-token"
  end

  # The sync no longer announces itself; writing its provider row does, through
  # the posture provider change hooks.
  test "refreshes when the device inventory changes", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    provider = intune_posture_provider_fixture(account: account)

    {:ok, lv, _html} =
      conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

    assert lv |> element("#device-posture-summary") |> render() =~ ~r/0.*Devices synced/s

    intune_device_fixture(provider: provider)

    send(lv.pid, %Portal.Changes.Change{
      lsn: 0,
      op: :update,
      old_struct: provider,
      struct: %{provider | synced_at: DateTime.utc_now()}
    })

    assert lv |> element("#device-posture-summary") |> render() =~ ~r/1.*Devices synced/s
  end

  test "replaces the Iru token only when a new one is typed", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    provider = iru_posture_provider_fixture(account: account, api_token: "old-token")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/device_posture/iru/#{provider.id}/edit")

    Req.Test.stub(Portal.Iru.APIClient, fn conn -> Req.Test.json(conn, []) end)
    Req.Test.allow(Portal.Iru.APIClient, self(), lv.pid)

    html =
      lv
      |> form("#device-posture-form", provider: %{api_token: "new-token"})
      |> render_change()

    # What the admin just typed is theirs to see; the stored one is not sent.
    assert html =~ "new-token"

    # A new token is a new claim on the tenant, so it has to be proven again.
    refute has_element?(lv, "#provider-verification-status", "Verified")
    lv |> element("#provider-verification-button") |> render_click()
    assert has_element?(lv, "#provider-verification-status", "Verified")

    lv
    |> form("#device-posture-form", provider: %{api_token: "new-token"})
    |> render_submit()

    assert Portal.Repo.get_by!(Portal.Iru.PostureProvider,
             account_id: provider.account_id,
             id: provider.id
           ).api_token == "new-token"
  end

  describe "Defender providers" do
    test "uses the signed Microsoft consent flow and creates the verified provider", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/defender/new")

      assert has_element?(lv, "#provider-tenant-id", "Awaiting verification...")
      assert render(lv) =~ "Grant Microsoft admin consent"

      lv |> element("#provider-verification-button") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      state =
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      assert {:ok, %{type: "defender-posture-provider", verification_ref: ref}} =
               PortalWeb.OIDC.verify_verification_state(state)

      send(lv.pid, {:get_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^ref}}

      ack_ref = make_ref()
      send(lv.pid, {:defender_posture_provider_complete, "tenant-9", ref, {self(), ack_ref}})
      assert_receive {:verification_ack, ^ack_ref}

      assert has_element?(lv, "#provider-verification-status", "Verified")
      assert has_element?(lv, "#provider-tenant-id", "tenant-9")

      lv
      |> form("#device-posture-form", provider: %{name: "Contoso EDR"})
      |> render_submit()

      assert_patch(lv, ~p"/#{account}/settings/device_posture")

      provider = Portal.Repo.get_by!(Portal.Defender.PostureProvider, account_id: account.id)
      assert provider_name(provider) == "Contoso EDR"
      assert provider.tenant_id == "tenant-9"
      assert provider.is_verified

      assert_enqueued(
        worker: Portal.Defender.Sync,
        args: %{"account_id" => account.id, "posture_provider_id" => provider.id}
      )
    end

    test "refuses a second provider for the same tenant", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      defender_posture_provider_fixture(account: account, tenant_id: "tenant-9")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/defender/new")

      lv |> element("#provider-verification-button") |> render_click()
      assert_push_event(lv, "open_url", %{url: url})

      state =
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

      send(lv.pid, {:get_pending_verification, self()})
      assert_receive {:pending_verification, %{verification_ref: ^ref}}

      ack_ref = make_ref()
      send(lv.pid, {:defender_posture_provider_complete, "tenant-9", ref, {self(), ack_ref}})
      assert_receive {:verification_ack, ^ack_ref}

      lv
      |> form("#device-posture-form", provider: %{name: "Duplicate EDR"})
      |> render_submit()

      assert render(lv) =~ "This Defender tenant is already connected."
      assert Portal.Repo.aggregate(Portal.Defender.PostureProvider, :count) == 1
    end
  end

  test "lists providers of every type", %{conn: conn, account: account, actor: actor} do
    intune_posture_provider_fixture(account: account, name: "Contoso Intune")
    iru_provider = iru_posture_provider_fixture(account: account, name: "Acme Iru")
    iru_device_fixture(provider: iru_provider, filevault_enabled: false)
    santa_provider = santa_posture_provider_fixture(account: account, name: "Acme Santa")
    santa_device_fixture(provider: santa_provider, last_seen_client_mode: "LOCKDOWN")

    defender_provider = defender_posture_provider_fixture(account: account, name: "Contoso EDR")
    defender_device_fixture(provider: defender_provider, health_status: "Active")
    defender_device_fixture(provider: defender_provider, health_status: "Inactive")

    sentinelone_provider =
      sentinelone_posture_provider_fixture(account: account, name: "Production S1")

    sentinelone_device_fixture(
      provider: sentinelone_provider,
      sentinelone_id: nil,
      is_active: true
    )

    sentinelone_device_fixture(provider: sentinelone_provider, is_active: true)
    sentinelone_device_fixture(provider: sentinelone_provider, is_active: false)

    {:ok, lv, html} =
      conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/device_posture")

    assert html =~ "Contoso Intune"
    assert html =~ "Acme Iru"
    assert html =~ "Iru (formerly Kandji)"
    assert html =~ "Contoso EDR"
    assert html =~ "Microsoft Defender for Endpoint"
    assert html =~ "Acme Santa"
    assert html =~ "Santa (Workshop)"
    assert html =~ "Production S1"
    assert html =~ "SentinelOne"

    summary = lv |> element("#device-posture-summary") |> render()
    assert summary =~ ~r/1.*FileVault off/s
    assert summary =~ ~r/1.*Sensor active/s
    assert summary =~ ~r/1.*Sensor inactive/s
    assert summary =~ ~r/1.*Santa Lockdown/s
    assert summary =~ ~r/2.*S1 agent active/s
    assert summary =~ ~r/1.*S1 agent inactive/s
  end

  describe "verified fields" do
    test "ignores a tenant and a verified flag posted by the browser", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/intune/new")

      refute html =~ ~s(name="provider[tenant_id]")

      lv
      |> element("#device-posture-form")
      |> render_change(%{
        "provider" => %{
          "name" => "Contoso",
          "tenant_id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
          "is_verified" => "true"
        }
      })

      lv |> element("#device-posture-form") |> render_submit()

      refute Portal.Repo.get_by(Portal.Intune.PostureProvider, account_id: account.id)
    end

    test "keeps the verified tenant when a later change posts another", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/device_posture/intune/new")

      verified = "11111111-1111-1111-1111-111111111111"
      reverify(lv, verified)

      lv
      |> element("#device-posture-form")
      |> render_change(%{
        "provider" => %{
          "name" => "Contoso",
          "tenant_id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        }
      })

      lv |> element("#device-posture-form") |> render_submit()

      assert provider = Portal.Repo.get_by(Portal.Intune.PostureProvider, account_id: account.id)
      assert provider.tenant_id == verified
    end
  end
end
