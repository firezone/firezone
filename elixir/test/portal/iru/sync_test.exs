defmodule Portal.Iru.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.DevicePostureFixtures
  import Portal.IruFixtures

  alias Portal.Iru.{APIClient, Device, PostureProvider, Sync}

  setup do
    enable_device_posture()
    stub_api([])
    :ok
  end

  test "stores every device in the tenant" do
    provider = iru_posture_provider_fixture()

    stub_api([
      device(%{
        "device_id" => "device-1",
        "device_name" => "Alice's MacBook Air",
        "serial_number" => "FVHHFKF7Q6L4"
      }),
      device(%{
        "device_id" => "device-2",
        "device_name" => "Bob's iPhone",
        "platform" => "iPhone",
        "user" => ""
      })
    ])

    assert :ok = perform_job(Sync, sync_args(provider))

    assert [first, second] = Repo.all(from(d in Device, order_by: d.iru_id))

    assert first.iru_id == "device-1"
    assert first.device_name == "Alice's MacBook Air"
    assert first.serial_number == "FVHHFKF7Q6L4"
    assert first.platform == "Mac"
    assert first.os_version == "14.4.1"
    assert first.supplemental_build_version == "23E224"
    assert first.model == "MacBook Air (M1, 2020)"
    assert first.blueprint_name == "main hive"
    assert first.agent_version == "4.5.9 (5160)"
    assert first.mdm_enabled
    assert first.agent_installed
    refute first.is_missing
    assert first.tags == ["accuhive_02"]
    assert first.last_check_in_at == ~U[2024-07-23 14:11:37.150080Z]
    assert first.first_enrolled_at == ~U[2024-01-26 16:15:36.087016Z]
    assert first.last_enrolled_at == ~U[2024-05-13 20:09:27.374451Z]
    assert first.user_id == "5344c996-8823-4b37-8d6e-8515fc7c3a0a"
    assert first.user_name == "Accuhive Admin"
    assert first.user_email == "accuhive.admin@kandji.io"
    refute first.user_is_archived
    assert first.account_id == provider.account_id
    assert first.posture_provider_id == provider.id

    # A device with no assigned user carries an empty string where the object
    # would be, not null.
    assert second.iru_id == "device-2"
    assert second.platform == "iPhone"
    refute second.user_email
    refute second.user_name
  end

  test "folds every per-device Prism category into the device row" do
    provider = iru_posture_provider_fixture()

    stub_api([device(%{"device_id" => "device-1"})],
      prism: %{
        "device_information" => [
          prism_row("device-1", %{
            "device__family" => "Mac",
            "host_name" => "alices-air",
            "local_hostname" => "Alices-MacBook-Air",
            "apple_silicon" => true,
            "model_name" => "MacBook Air (M1, 2020)",
            "model_identifier" => "MacBookAir10,1",
            "device_capacity" => 245.0,
            "os_build" => "23E224",
            "display_os_version" => "14.4.1",
            "last_collected_at" => "2024-07-23T14:11:37.150080Z"
          })
        ],
        "filevault" => [
          prism_row("device-1", %{
            "status" => true,
            "key_type" => "Personal Recovery Key",
            "key_escrowed" => true,
            "regeneration_needed" => false,
            "scheduled_key_rotation" => "2024-09-10T11:48:00.610908Z"
          })
        ],
        "application_firewall" => [
          prism_row("device-1", %{
            "status" => true,
            "block_all_incoming" => false,
            "logging" => true,
            "logging_option" => "throttled",
            "stealth_mode" => true,
            "version" => "1.7",
            "allow_signed_applications" => true,
            "unloading" => false
          })
        ],
        "gatekeeper_and_xprotect" => [
          prism_row("device-1", %{
            "gatekeeper_status" => true,
            "trusted_developers" => true,
            "gatekeeper_version" => "8.0",
            "gatekeeper_opaque_version" => "94",
            "xprotect_version" => "5283",
            "malware_removal_tool_version" => "1.93"
          })
        ],
        "startup_settings" => [
          prism_row("device-1", %{
            "sip" => true,
            "ssv" => true,
            "bootstrap_token_auth" => false,
            "bootstrap_token_escrowed" => true,
            "kext_requires_bst" => true,
            "software_update_requires_bst" => true,
            "external_boot_level" => "allowed",
            "secure_boot_level" => "full"
          })
        ],
        "activation_lock" => [
          prism_row("device-1", %{
            "activation_lock_supported" => true,
            "activation_lock_allowed_while_supervised" => false,
            "device_activation_lock_enabled" => true,
            "user_activation_lock_enabled" => false,
            "bypass_code_failed" => false
          })
        ]
      }
    )

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, iru_id: "device-1")

    assert device.device_family == "Mac"
    assert device.host_name == "alices-air"
    assert device.local_hostname == "Alices-MacBook-Air"
    assert device.apple_silicon
    assert device.model_name == "MacBook Air (M1, 2020)"
    assert device.model_identifier == "MacBookAir10,1"
    assert device.device_capacity_gb == 245.0
    assert device.os_build == "23E224"
    assert device.display_os_version == "14.4.1"
    assert device.inventory_collected_at == ~U[2024-07-23 14:11:37.150080Z]

    assert device.filevault_enabled
    assert device.filevault_key_type == "Personal Recovery Key"
    assert device.filevault_key_escrowed
    refute device.filevault_regeneration_needed
    assert device.filevault_key_rotation_scheduled_at == ~U[2024-09-10 11:48:00.610908Z]

    assert device.firewall_enabled
    refute device.firewall_block_all_incoming
    assert device.firewall_logging
    assert device.firewall_logging_option == "throttled"
    assert device.firewall_stealth_mode
    assert device.firewall_version == "1.7"
    assert device.firewall_allow_signed_applications
    refute device.firewall_unloading

    assert device.gatekeeper_enabled
    assert device.gatekeeper_trusted_developers
    assert device.gatekeeper_version == "8.0"
    assert device.gatekeeper_opaque_version == "94"
    assert device.xprotect_version == "5283"
    assert device.malware_removal_tool_version == "1.93"

    assert device.sip_enabled
    assert device.ssv_enabled
    refute device.bootstrap_token_auth
    assert device.bootstrap_token_escrowed
    assert device.kext_requires_bootstrap_token
    assert device.software_update_requires_bootstrap_token
    assert device.external_boot_level == "allowed"
    assert device.secure_boot_level == "full"

    assert device.activation_lock_supported
    refute device.activation_lock_allowed_while_supervised
    assert device.device_activation_lock_enabled
    refute device.user_activation_lock_enabled
    refute device.activation_lock_bypass_code_failed

    # The base list still owns the fields both endpoints report.
    assert device.model == "MacBook Air (M1, 2020)"
  end

  test "pages through the device list" do
    provider = iru_posture_provider_fixture()

    devices = for n <- 1..305, do: device(%{"device_id" => "device-#{n}"})
    stub_api(devices)

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.aggregate(Device, :count) == 305
  end

  test "leaves a refused Prism category unset and keeps the rest of the sync" do
    provider = iru_posture_provider_fixture()

    stub_api([device(%{"device_id" => "device-1"})],
      prism: %{"filevault" => [prism_row("device-1", %{"status" => true})]},
      errors: %{"startup_settings" => 403, "activation_lock" => 404}
    )

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, iru_id: "device-1")
    assert device.filevault_enabled
    refute device.sip_enabled
    refute device.activation_lock_supported

    assert Repo.get_by!(PostureProvider,
             account_id: provider.account_id,
             id: provider.id
           ).synced_at
  end

  test "clears the fields of a category the token stopped being allowed to read" do
    provider = iru_posture_provider_fixture()

    stub_api([device(%{"device_id" => "device-1"})],
      prism: %{"filevault" => [prism_row("device-1", %{"status" => true, "key_escrowed" => true})]}
    )

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.get_by!(Device, iru_id: "device-1").filevault_enabled

    stub_api([device(%{"device_id" => "device-1"})], errors: %{"filevault" => 403})

    assert :ok = perform_job(Sync, sync_args(provider))

    device = Repo.get_by!(Device, iru_id: "device-1")
    refute device.filevault_enabled
    refute device.filevault_key_escrowed
    refute device.filevault_collected_at
    assert device.device_name == "Alice's MacBook Air"
  end

  test "clears the fields of a device a category stopped reporting" do
    provider = iru_posture_provider_fixture()

    devices = [device(%{"device_id" => "device-1"}), device(%{"device_id" => "device-2"})]

    stub_api(devices,
      prism: %{
        "filevault" => [
          prism_row("device-1", %{"status" => true}),
          prism_row("device-2", %{"status" => true})
        ]
      }
    )

    assert :ok = perform_job(Sync, sync_args(provider))

    stub_api(devices, prism: %{"filevault" => [prism_row("device-1", %{"status" => true})]})

    assert :ok = perform_job(Sync, sync_args(provider))

    assert Repo.get_by!(Device, iru_id: "device-1").filevault_enabled
    refute Repo.get_by!(Device, iru_id: "device-2").filevault_enabled
  end

  test "ignores Prism rows for devices the tenant did not list" do
    provider = iru_posture_provider_fixture()

    stub_api([device(%{"device_id" => "device-1"})],
      prism: %{
        "filevault" => [
          prism_row("device-1", %{"status" => true}),
          prism_row("removed-device", %{"status" => false})
        ]
      }
    )

    assert :ok = perform_job(Sync, sync_args(provider))

    assert [%Device{iru_id: "device-1"}] = Repo.all(Device)
  end

  test "raises when the tenant refuses the device list" do
    provider = iru_posture_provider_fixture()

    Req.Test.stub(APIClient, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"detail" => "Invalid token."})
    end)

    assert_raise Portal.Iru.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
  end

  test "raises when a device comes back without an id" do
    provider = iru_posture_provider_fixture()

    stub_api([device(%{"device_id" => nil})])

    assert_raise Portal.Iru.SyncError, fn -> perform_job(Sync, sync_args(provider)) end
  end

  test "deletes devices the tenant no longer reports" do
    provider = iru_posture_provider_fixture()
    stale = iru_device_fixture(provider: provider, iru_id: "stale-device")

    stub_api([device(%{"device_id" => "device-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    refute Repo.get_by(Device, account_id: provider.account_id, iru_id: stale.iru_id)
    assert Repo.get_by(Device, account_id: provider.account_id, iru_id: "device-1")
  end

  test "records the sync and clears earlier errors on the provider" do
    provider =
      iru_posture_provider_fixture(
        errored_at: DateTime.utc_now(),
        error_message: "401 - Invalid token.",
        error_email_count: 2
      )

    stub_api([device(%{"device_id" => "device-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))

    provider =
      Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)

    assert provider.synced_at
    refute provider.errored_at
    refute provider.error_message
    assert provider.error_email_count == 0
  end

  # A run that started while the provider was enabled must not undo an admin who
  # disabled it while the run was still going.
  test "leaves a provider disabled mid-run disabled" do
    provider = iru_posture_provider_fixture()

    stub_api([device(%{"device_id" => "device-1"})],
      on_request: fn ->
        Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
        |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Disabled by admin")
        |> Repo.update!()
      end
    )

    assert :ok = perform_job(Sync, sync_args(provider))

    reloaded = Repo.get_by!(PostureProvider, account_id: provider.account_id, id: provider.id)
    assert reloaded.synced_at
    assert reloaded.is_disabled
    assert reloaded.disabled_reason == "Disabled by admin"
  end

  test "skips a disabled provider" do
    provider = iru_posture_provider_fixture(is_disabled: true)

    stub_api([device(%{"device_id" => "device-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  test "skips every provider when the global flag is off" do
    provider = iru_posture_provider_fixture()
    enable_device_posture(false)

    stub_api([device(%{"device_id" => "device-1"})])

    assert :ok = perform_job(Sync, sync_args(provider))
    assert Repo.aggregate(Device, :count) == 0
  end

  defp sync_args(provider) do
    %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
  end

  defp device(overrides) do
    Map.merge(
      %{
        "device_id" => "device-1",
        "device_name" => "Alice's MacBook Air",
        "model" => "MacBook Air (M1, 2020)",
        "serial_number" => "FVHHFKF7Q6L4",
        "platform" => "Mac",
        "os_version" => "14.4.1",
        "supplemental_build_version" => "23E224",
        "supplemental_os_version_extra" => "",
        "last_check_in" => "2024-07-23T14:11:37.150080Z",
        "user" => %{
          "email" => "accuhive.admin@kandji.io",
          "name" => "Accuhive Admin",
          "id" => "5344c996-8823-4b37-8d6e-8515fc7c3a0a",
          "is_archived" => false
        },
        "asset_tag" => "",
        "blueprint_id" => "ab102b9d-8e9c-420d-a498-f2a1123091c7",
        "blueprint_name" => "main hive",
        "mdm_enabled" => true,
        "agent_installed" => true,
        "is_missing" => false,
        "is_removed" => false,
        "agent_version" => "4.5.9 (5160)",
        "first_enrollment" => "2024-01-26 16:15:36.087016+00:00",
        "last_enrollment" => "2024-05-13 20:09:27.374451+00:00",
        "lost_mode_status" => "",
        "tags" => ["accuhive_02"]
      },
      overrides
    )
  end

  defp prism_row(device_id, attrs) do
    Map.merge(%{"device_id" => device_id, "serial_number" => "FVHHFKF7Q6L4"}, attrs)
  end

  defp stub_api(devices, opts \\ []) do
    prism = Keyword.get(opts, :prism, %{})
    errors = Keyword.get(opts, :errors, %{})
    on_request = Keyword.get(opts, :on_request, fn -> :ok end)

    Req.Test.stub(APIClient, fn conn ->
      on_request.()
      conn = Plug.Conn.fetch_query_params(conn)
      offset = String.to_integer(conn.query_params["offset"] || "0")
      limit = String.to_integer(conn.query_params["limit"] || "300")

      case conn.request_path do
        "/api/v1/devices" ->
          Req.Test.json(conn, Enum.slice(devices, offset, limit))

        "/api/v1/prism/" <> category ->
          case Map.fetch(errors, category) do
            {:ok, status} ->
              conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"detail" => "denied"})

            :error ->
              rows = prism |> Map.get(category, []) |> Enum.slice(offset, limit)
              Req.Test.json(conn, %{"data" => rows, "cursor" => nil})
          end
      end
    end)
  end
end
