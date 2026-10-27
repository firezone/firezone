defmodule Portal.Ops.RegionTransferTest do
  use Portal.DataCase, async: true
  import ExUnit.CaptureIO
  import Portal.AccountFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  alias Portal.Ops.RegionTransfer

  setup do
    Portal.Config.put_env_override(:data_residency_region, :us)
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    group = group_fixture(account: account)
    membership_fixture(account: account, actor: actor, group: group)
    site = site_fixture(account: account)
    # A single-owner token points back at its gateway, so both halves of the
    # devices <-> gateway_tokens cycle are set.
    gateway = gateway_fixture(account: account, site: site, token: :single_owner)
    resource = resource_fixture(account: account, site: site)
    policy_fixture(account: account, group: group, resource: resource)
    client = client_fixture(account: account, actor: actor)

    dir = Path.join(System.tmp_dir!(), "region-transfer-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(dir) end)

    %{account: account, actor: actor, gateway: gateway, client: client, dir: dir}
  end

  describe "export/2" do
    test "disables the account and writes one file per table", %{account: account, dir: dir} do
      output =
        capture_io("y\n", fn ->
          assert {:ok, manifest} = RegionTransfer.export(account.id, dir)
          assert manifest["account_id"] == account.id
          assert manifest["slug"] == account.slug
          assert Enum.any?(manifest["tables"], &(&1["name"] == "devices" and &1["rows"] == 2))
          refute Enum.any?(manifest["tables"], &(&1["name"] in ~w(client_tokens portal_sessions api_request_logs)))
        end)

      assert output =~ "Export of account #{account.name}"
      assert output =~ "devices"
      assert File.exists?(Path.join(dir, "manifest.json"))
      assert File.exists?(Path.join(dir, "accounts.copy"))
      assert File.exists?(Path.join(dir, "devices.copy"))

      account = Repo.reload!(account)
      assert account.is_disabled
      assert account.disabled_reason == "Region transfer in progress"
    end

    test "emails the admins that the account is disabled for the move", %{
      account: account,
      actor: actor,
      dir: dir
    } do
      capture_io("y\n", fn -> {:ok, _manifest} = RegionTransfer.export(account.id, dir) end)

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Transfer in Progress"
      assert email.text_body =~ "moved to the European Union region"
      assert email.text_body =~ "every session, Gateway token, and API token is invalid"
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [actor.email]
    end

    test "cuts the devices and gateway_tokens cycle through a nullable column", %{
      account: account,
      dir: dir
    } do
      capture_io("y\n", fn ->
        assert {:ok, manifest} = RegionTransfer.export(account.id, dir)

        deferred =
          manifest["tables"]
          |> Enum.filter(&(&1["deferred_columns"] != []))
          |> Map.new(&{&1["name"], &1["deferred_columns"]})

        assert deferred == %{"devices" => ["gateway_token_id"]}
      end)
    end

    test "does nothing without confirmation", %{account: account, dir: dir} do
      output =
        capture_io("n\n", fn ->
          assert :aborted = RegionTransfer.export(account.id, dir)
        end)

      assert output =~ "Aborted."
      refute File.exists?(dir)
      refute Repo.reload!(account).is_disabled
    end
  end

  describe "import/1" do
    setup %{account: account, dir: dir} do
      capture_io("y\n", fn -> {:ok, _manifest} = RegionTransfer.export(account.id, dir) end)
      :ok
    end

    test "refuses while the account still exists", %{dir: dir} do
      assert {:error, :account_exists} = RegionTransfer.import(dir)
    end

    test "refuses a manifest from another schema version", %{account: account, dir: dir} do
      Repo.delete!(account)
      path = Path.join(dir, "manifest.json")
      manifest = path |> File.read!() |> Jason.decode!()
      File.write!(path, Jason.encode!(%{manifest | "schema_version" => 1}))

      assert {:error, {:schema_version_mismatch, exported: 1, local: _local}} = RegionTransfer.import(dir)
    end

    test "restores every row and the cut foreign keys", %{
      account: account,
      actor: actor,
      gateway: gateway,
      client: client,
      dir: dir
    } do
      counts = row_counts(account.id)
      Repo.delete!(account)
      assert row_counts(account.id) == Map.new(counts, fn {table, _count} -> {table, 0} end)

      output =
        capture_io("y\n", fn ->
          assert {:ok, _manifest} = RegionTransfer.import(dir)
        end)

      assert output =~ "Import of account #{account.name}"
      assert output =~ "Imported"

      assert row_counts(account.id) == counts

      imported = Repo.get!(Portal.Account, account.id)
      assert imported.slug == account.slug
      assert imported.is_disabled

      imported_gateway = Repo.get_by!(Portal.Device, id: gateway.id)
      assert imported_gateway.gateway_token_id == gateway.gateway_token_id
      assert Repo.get_by!(Portal.GatewayToken, id: gateway.gateway_token_id).device_id == gateway.id
      assert Repo.get_by!(Portal.Device, id: client.id).actor_id == client.actor_id

      Portal.Config.put_env_override(:data_residency_region, :eu)
      assert {:ok, enabled} = RegionTransfer.enable(account.id)
      refute enabled.is_disabled
      assert is_nil(enabled.disabled_reason)

      assert email =
               Enum.find(collect_queued_emails(account.id), &(&1.subject == "Firezone Account Transfer Complete"))

      assert email.text_body =~ "now in the European Union region"
      assert email.text_body =~ "/#{account.slug}"
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [actor.email]
    end

    test "does nothing without confirmation", %{account: account, dir: dir} do
      Repo.delete!(account)

      capture_io("n\n", fn ->
        assert :aborted = RegionTransfer.import(dir)
      end)

      refute Repo.get(Portal.Account, account.id)
    end
  end

  defp row_counts(account_id) do
    id = Ecto.UUID.dump!(account_id)

    Map.new(~w(actors devices gateway_tokens groups memberships policies resources sites), fn table ->
      %{rows: [[count]]} = Repo.query!(~s[SELECT count(*) FROM "#{table}" WHERE account_id = $1], [id])
      {table, count}
    end)
  end
end
