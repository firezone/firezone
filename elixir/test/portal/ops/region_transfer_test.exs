defmodule Portal.Ops.RegionTransferTest do
  use Portal.DataCase, async: true
  import ExUnit.CaptureIO
  import Plug.Conn
  import Portal.AccountFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures
  alias Portal.Ops.RegionTransfer

  @container_url "https://transfers.example.test/transfers"

  setup do
    Portal.Config.put_env_override(:data_residency_region, :us)
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    group = group_fixture(account: account)
    membership_fixture(account: account, actor: actor, group: group)
    site = site_fixture(account: account)
    # Both devices point at tokens, which are not moved.
    gateway = gateway_fixture(account: account, site: site, token: :single_owner)
    resource = resource_fixture(account: account, site: site)
    policy_fixture(account: account, group: group, resource: resource)
    client_token = client_token_fixture(account: account, actor: actor)

    client =
      client_fixture(account: account, actor: actor)
      |> Ecto.Changeset.change(token_id: client_token.id)
      |> update!()

    %{account: account, actor: actor, gateway: gateway, client: client, store: stub_storage()}
  end

  describe "export/2" do
    test "disables the account and uploads one file per table", %{account: account, store: store} do
      output =
        capture_io("y\n", fn ->
          assert {:ok, manifest} = RegionTransfer.export(account.id)
          assert manifest["account_id"] == account.id
          assert manifest["slug"] == account.slug
          assert Enum.any?(manifest["tables"], &(&1["name"] == "devices" and &1["rows"] == 2))
          assert manifest["slugs"] == [account.slug]

          refute Enum.any?(
                   manifest["tables"],
                   &(&1["name"] in ~w(device_tokens log_sink_cursors pending_identities portal_sessions api_request_logs))
                 )
        end)

      assert output =~ "Export of account #{account.name}"
      assert output =~ "devices"
      assert blob(store, account.id, "manifest.json")
      assert blob(store, account.id, "accounts.copy")
      assert blob(store, account.id, "devices.copy")

      account = fetch_account(account.id)
      assert account.is_disabled
      assert account.disabled_reason == "Region transfer in progress"
    end

    test "emails the admins that the account is disabled for the move", %{
      account: account,
      actor: actor
    } do
      capture_io("y\n", fn -> {:ok, _manifest} = RegionTransfer.export(account.id) end)

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Transfer in Progress"
      assert email.text_body =~ "moved to the European Union region"
      assert email.text_body =~ "every session, Gateway token, service account token, and API token is invalid"
      assert email.text_body =~ "MCP clients have to be reconnected"
      assert email.text_body =~ "Windows and Linux 1.5.20 or later switch to the new region"
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [actor.email]
    end

    test "exports foreign keys to tables that are not moved as NULL", %{account: account} do
      capture_io(fn -> send(self(), RegionTransfer.export(account.id, confirm: false)) end)
      assert_received {:ok, manifest}

      nulled =
        manifest["tables"]
        |> Enum.filter(&(&1["nulled_columns"] != []))
        |> Map.new(&{&1["name"], Enum.sort(&1["nulled_columns"])})

      assert nulled == %{"devices" => ["client_token_id", "gateway_token_id", "token_id"]}
    end

    test "refuses an account disabled for another reason", %{account: account, store: store} do
      account |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Stripe") |> update!()

      assert {:error, {:account_disabled, "Stripe"}} = RegionTransfer.export(account.id, confirm: false)
      assert Agent.get(store, & &1) == %{}
      assert fetch_account(account.id).disabled_reason == "Stripe"
    end

    test "does nothing without confirmation", %{account: account, store: store} do
      output =
        capture_io("n\n", fn ->
          assert :aborted = RegionTransfer.export(account.id)
        end)

      assert output =~ "Aborted."
      assert Agent.get(store, & &1) == %{}
      refute fetch_account(account.id).is_disabled
    end
  end

  describe "import/2" do
    setup %{account: account} do
      capture_io("y\n", fn -> {:ok, _manifest} = RegionTransfer.export(account.id) end)
      :ok
    end

    test "refuses an account that was not exported" do
      assert {:error, :export_not_found} = RegionTransfer.import(Ecto.UUID.generate())
    end

    test "refuses while the account still exists", %{account: account} do
      assert {:error, :account_exists} = RegionTransfer.import(account.id)
    end

    test "refuses a manifest from another schema version", %{account: account, store: store} do
      delete!(account)
      manifest = store |> blob(account.id, "manifest.json") |> Jason.decode!()
      put_blob(store, account.id, "manifest.json", Jason.encode!(%{manifest | "schema_version" => 1}))

      assert {:error, {:schema_version_mismatch, exported: 1, local: _local}} = RegionTransfer.import(account.id)
    end

    test "rolls back when a file does not match its checksum", %{account: account, store: store} do
      delete!(account)
      put_blob(store, account.id, "devices.copy", "")

      capture_io(fn ->
        assert {:error, {:checksum_mismatch, "devices"}} = RegionTransfer.import(account.id, confirm: false)
      end)

      refute fetch_account(account.id)
    end

    test "refuses when another account holds one of the slugs", %{account: account} do
      delete!(account)
      other = account_fixture()

      insert!(%Portal.AccountSlug{
        slug: String.replace(account.slug, "_", "-"),
        account_id: other.id
      })

      assert {:error, {:slugs_taken, [_slug]}} = RegionTransfer.import(account.id, confirm: false)
      refute fetch_account(account.id)
    end

    test "restores every row without the tokens", %{
      account: account,
      actor: actor,
      gateway: gateway,
      client: client
    } do
      counts = row_counts(account.id)
      delete!(account)
      assert row_counts(account.id) == Map.new(counts, fn {table, _count} -> {table, 0} end)

      output =
        capture_io("y\n", fn ->
          assert {:ok, _manifest} = RegionTransfer.import(account.id)
        end)

      assert output =~ "Import of account #{account.name}"
      assert output =~ "Imported"

      assert row_counts(account.id) == counts

      imported = fetch_account(account.id)
      assert imported.slug == account.slug
      assert imported.is_disabled

      assert is_nil(fetch_device(gateway.id).token_id)
      imported_client = fetch_device(client.id)
      assert imported_client.actor_id == client.actor_id
      assert is_nil(imported_client.token_id)

      Portal.Config.put_env_override(:data_residency_region, :eu)
      assert {:ok, enabled} = RegionTransfer.enable(account.id, confirm: false)
      refute enabled.is_disabled
      assert is_nil(enabled.disabled_reason)

      assert email =
               Enum.find(collect_queued_emails(account.id), &(&1.subject == "Firezone Account Transfer Complete"))

      assert email.text_body =~ "now in the European Union region"
      assert email.text_body =~ "Create new service account tokens for your headless Clients."
      assert email.text_body =~ "Reconnect your MCP clients."
      assert email.text_body =~ "macOS and iOS 1.5.24, Android 1.5.18"
      assert email.text_body =~ "set the auth URL to http"
      assert email.text_body =~ "/#{account.slug}"
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [actor.email]
    end

    test "copies the suppressed addresses of the account's actors" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      suppression = insert!(%Portal.EmailSuppression{email: Portal.EmailSuppression.normalize_email(actor.email)})
      capture_io(fn -> {:ok, _manifest} = RegionTransfer.export(account.id, confirm: false) end)
      delete!(account)
      delete!(suppression)

      capture_io(fn -> assert {:ok, _manifest} = RegionTransfer.import(account.id, confirm: false) end)
      assert Repo.get_by(Portal.EmailSuppression, email: suppression.email)
    end

    test "does nothing without confirmation", %{account: account} do
      delete!(account)

      capture_io("n\n", fn ->
        assert :aborted = RegionTransfer.import(account.id)
      end)

      refute fetch_account(account.id)
    end
  end

  describe "enable/2" do
    test "refuses an account that is not being transferred", %{account: account} do
      assert {:error, {:not_in_transfer, nil}} = RegionTransfer.enable(account.id, confirm: false)

      account |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Stripe") |> update!()
      assert {:error, {:not_in_transfer, "Stripe"}} = RegionTransfer.enable(account.id, confirm: false)
      assert fetch_account(account.id).is_disabled
    end

    test "rolls back without emailing the admins", %{account: account} do
      capture_io(fn -> {:ok, _manifest} = RegionTransfer.export(account.id, confirm: false) end)
      started = collect_queued_emails(account.id)

      assert {:ok, enabled} = RegionTransfer.enable(account.id, confirm: false, notify: false)
      refute enabled.is_disabled
      assert collect_queued_emails(account.id) == started
    end

    test "does nothing without confirmation", %{account: account} do
      capture_io(fn -> {:ok, _manifest} = RegionTransfer.export(account.id, confirm: false) end)

      capture_io("n\n", fn -> assert :aborted = RegionTransfer.enable(account.id) end)
      assert fetch_account(account.id).is_disabled
    end
  end

  # Both settings point at one in-memory container, so a test exports and
  # imports in the same region.
  defp stub_storage do
    Portal.Config.put_env_override(:region_transfer_outbox_url, @container_url)
    Portal.Config.put_env_override(:region_transfer_inbox_url, @container_url)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{"access_token" => "storage-token", "expires_on" => "4102444800"})
    end)

    store = start_supervised!({Agent, fn -> %{} end})

    Req.Test.stub(RegionTransfer.Storage, fn
      %{method: "PUT"} = conn ->
        ["Bearer storage-token"] = get_req_header(conn, "authorization")
        {:ok, body, conn} = read_body(conn)
        Agent.update(store, &Map.put(&1, conn.request_path, body))
        send_resp(conn, 201, "")

      %{method: "GET"} = conn ->
        case Agent.get(store, &Map.fetch(&1, conn.request_path)) do
          {:ok, body} -> send_resp(conn, 200, body)
          :error -> send_resp(conn, 404, "")
        end
    end)

    store
  end

  defp blob(store, account_id, name), do: Agent.get(store, &Map.get(&1, "/transfers/#{account_id}/#{name}"))

  defp put_blob(store, account_id, name, body),
    do: Agent.update(store, &Map.put(&1, "/transfers/#{account_id}/#{name}", body))

  defp row_counts(account_id) do
    id = Ecto.UUID.dump!(account_id)

    Map.new(~w(actors devices groups memberships policies resources site_devices sites), fn table ->
      %{rows: [[count]]} = Repo.query!(~s[SELECT count(*) FROM "#{table}" WHERE account_id = $1], [id])
      {table, count}
    end)
  end

  defp fetch_device(id), do: Repo.get_by!(Portal.Device, id: id)

  defp update!(changeset), do: Repo.update!(changeset)

  defp insert!(struct), do: Repo.insert!(struct)

  defp delete!(struct), do: Repo.delete!(struct)
end
