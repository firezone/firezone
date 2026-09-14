defmodule Portal.Intune.Sync do
  @moduledoc """
  Synchronizes the managed device list from a Microsoft Intune tenant.
  """

  use Oban.Worker,
    queue: :intune_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.Intune
  alias Portal.Microsoft.Graph.APIClient
  alias __MODULE__.Database

  @replace_fields Portal.Intune.Device.__schema__(:fields) --
                    [:account_id, :posture_provider_id, :intune_id, :inserted_at]

  # Postgres binds at most 65535 parameters per statement and a device carries a
  # column per Graph property, so a full page of 999 would not fit in one insert.
  # Derived from the field count so adding a column cannot silently overflow it.
  @upsert_chunk_size div(65_535, length(Portal.Intune.Device.__schema__(:fields)))

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"account_id" => account_id, "posture_provider_id" => provider_id}
      }) do
    if Portal.Features.enabled?(:device_posture) do
      sync(account_id, provider_id)
    else
      :ok
    end
  end

  def perform(_), do: :ok

  # A downgrade has to stop the syncing that is already queued, not just the
  # scheduling of new runs, so the account is re-checked here rather than only
  # in the scheduler.
  defp sync(account_id, provider_id) do
    case Database.get_provider(account_id, provider_id) do
      nil ->
        Logger.info("Intune provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%Intune.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    access_token = get_access_token!(provider)

    APIClient.stream_managed_devices(access_token)
    |> Stream.each(fn
      devices when is_list(devices) -> sync_page(provider, devices, started_at)
      {:error, error} -> raise_sync_error(provider, :list_managed_devices, error)
    end)
    |> Stream.run()

    Database.delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished Intune device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id
    )

    :ok
  end

  defp get_access_token!(provider) do
    case APIClient.get_access_token(:intune, provider.tenant_id) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} ->
        access_token

      {:ok, %Req.Response{} = response} ->
        raise_sync_error(provider, :get_access_token, response)

      {:error, error} ->
        raise_sync_error(provider, :get_access_token, error)
    end
  end

  defp sync_page(_provider, [], _started_at), do: :ok

  defp sync_page(provider, graph_devices, started_at) do
    validate_devices!(provider, graph_devices)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    graph_devices
    |> Enum.map(fn graph_device ->
      graph_device
      |> device_attrs(provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @replace_fields))
  end

  defp validate_devices!(provider, graph_devices) do
    unless Enum.all?(graph_devices, &(is_binary(&1["id"]) and &1["id"] != "")) do
      raise_sync_error(provider, :validate_managed_devices, :missing_device_id)
    end
  end

  # Every property of the Graph v1.0 managedDevice resource, in the order the
  # reference documents them, so the two can be diffed by eye when Microsoft
  # adds a field. `activationLockBypassCode` is deliberately absent: it defeats
  # Apple Activation Lock and we have no use for it.
  @text_fields [
    {:intune_id, "id"},
    {:user_id, "userId"},
    {:device_name, "deviceName"},
    {:managed_device_owner_type, "managedDeviceOwnerType"},
    {:operating_system, "operatingSystem"},
    {:compliance_state, "complianceState"},
    # Returned on every device but missing from the v1.0 property table.
    {:management_state, "managementState"},
    {:management_agent, "managementAgent"},
    {:os_version, "osVersion"},
    {:eas_device_id, "easDeviceId"},
    {:device_enrollment_type, "deviceEnrollmentType"},
    {:email_address, "emailAddress"},
    {:entra_device_id, "azureADDeviceId"},
    {:device_registration_state, "deviceRegistrationState"},
    {:device_category_display_name, "deviceCategoryDisplayName"},
    {:exchange_access_state, "exchangeAccessState"},
    {:exchange_access_state_reason, "exchangeAccessStateReason"},
    {:user_principal_name, "userPrincipalName"},
    {:model, "model"},
    {:manufacturer, "manufacturer"},
    {:imei, "imei"},
    {:serial_number, "serialNumber"},
    {:phone_number, "phoneNumber"},
    {:user_display_name, "userDisplayName"},
    {:wifi_mac_address, "wiFiMacAddress"},
    {:subscriber_carrier, "subscriberCarrier"},
    {:meid, "meid"},
    {:managed_device_name, "managedDeviceName"},
    {:partner_reported_threat_state, "partnerReportedThreatState"},
    {:iccid, "iccid"},
    {:udid, "udid"},
    {:notes, "notes"},
    {:ethernet_mac_address, "ethernetMacAddress"},
    {:enrollment_profile_name, "enrollmentProfileName"}
  ]

  @boolean_fields [
    {:eas_activated, "easActivated"},
    {:entra_registered, "azureADRegistered"},
    {:is_supervised, "isSupervised"},
    {:is_encrypted, "isEncrypted"},
    {:require_user_enrollment_approval, "requireUserEnrollmentApproval"}
  ]

  @integer_fields [
    {:total_storage_space_bytes, "totalStorageSpaceInBytes"},
    {:free_storage_space_bytes, "freeStorageSpaceInBytes"},
    {:physical_memory_bytes, "physicalMemoryInBytes"}
  ]

  @datetime_fields [
    {:enrolled_at, "enrolledDateTime"},
    {:last_sync_at, "lastSyncDateTime"},
    {:eas_activated_at, "easActivationDateTime"},
    {:exchange_last_successful_sync_at, "exchangeLastSuccessfulSyncDateTime"},
    {:compliance_grace_period_expiration_at, "complianceGracePeriodExpirationDateTime"},
    {:management_certificate_expires_at, "managementCertificateExpirationDate"}
  ]

  @config_manager_fields [
    {:config_manager_inventory, "inventory"},
    {:config_manager_modern_apps, "modernApps"},
    {:config_manager_resource_access, "resourceAccess"},
    {:config_manager_device_configuration, "deviceConfiguration"},
    {:config_manager_compliance_policy, "compliancePolicy"},
    {:config_manager_windows_update_for_business, "windowsUpdateForBusiness"}
  ]

  @attestation_text_fields [
    {:attestation_last_update_date_time, "lastUpdateDateTime"},
    {:attestation_content_namespace_url, "contentNamespaceUrl"},
    {:attestation_status, "deviceHealthAttestationStatus"},
    {:attestation_content_version, "contentVersion"},
    {:attestation_identity_key, "attestationIdentityKey"},
    {:attestation_boot_manager_version, "bootManagerVersion"},
    {:attestation_code_integrity_check_version, "codeIntegrityCheckVersion"},
    {:attestation_pcr_hash_algorithm, "pcrHashAlgorithm"},
    {:attestation_boot_app_security_version, "bootAppSecurityVersion"},
    {:attestation_boot_manager_security_version, "bootManagerSecurityVersion"},
    {:attestation_tpm_version, "tpmVersion"},
    {:attestation_pcr0, "pcr0"},
    {:attestation_secure_boot_config_policy_fingerprint,
     "secureBootConfigurationPolicyFingerPrint"},
    {:attestation_code_integrity_policy, "codeIntegrityPolicy"},
    {:attestation_boot_revision_list_info, "bootRevisionListInfo"},
    {:attestation_operating_system_rev_list_info, "operatingSystemRevListInfo"},
    {:attestation_health_status_mismatch_info, "healthStatusMismatchInfo"}
  ]

  @attestation_integer_fields [
    {:attestation_reset_count, "resetCount"},
    {:attestation_restart_count, "restartCount"}
  ]

  # Booleans in the underlying health attestation report that Graph types as
  # String. Their spelling is not documented, so the flag parser is lenient.
  @attestation_flag_fields [
    {:attestation_data_execution_policy_enabled, "dataExcutionPolicy"},
    {:attestation_bit_locker_enabled, "bitLockerStatus"},
    {:attestation_secure_boot, "secureBoot"},
    {:attestation_boot_debugging, "bootDebugging"},
    {:attestation_operating_system_kernel_debugging, "operatingSystemKernelDebugging"},
    {:attestation_code_integrity, "codeIntegrity"},
    {:attestation_test_signing, "testSigning"},
    {:attestation_safe_mode, "safeMode"},
    {:attestation_windows_pe, "windowsPE"},
    {:attestation_early_launch_anti_malware_driver_protection,
     "earlyLaunchAntiMalwareDriverProtection"},
    {:attestation_virtual_secure_mode, "virtualSecureMode"},
    {:attestation_supported, "healthAttestationSupportedStatus"}
  ]

  defp device_attrs(graph_device, provider, synced_at) do
    config_manager = graph_device["configurationManagerClientEnabledFeatures"] || %{}
    attestation = graph_device["deviceHealthAttestationState"] || %{}

    %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      device_action_results: list_or_nil(graph_device["deviceActionResults"]),
      attestation_issued_at: parse_datetime(attestation["issuedDateTime"]),
      jail_broken: flag_or_nil(graph_device["jailBroken"]),
      android_security_patch_level: parse_date(graph_device["androidSecurityPatchLevel"]),
      synced_at: synced_at
    }
    |> take(graph_device, @text_fields, &nil_if_blank/1)
    |> take(graph_device, @boolean_fields, &boolean_or_nil/1)
    |> take(graph_device, @integer_fields, &integer_or_nil/1)
    |> take(graph_device, @datetime_fields, &parse_datetime/1)
    |> take(config_manager, @config_manager_fields, &boolean_or_nil/1)
    |> take(attestation, @attestation_text_fields, &nil_if_blank/1)
    |> take(attestation, @attestation_integer_fields, &integer_or_nil/1)
    |> take(attestation, @attestation_flag_fields, &flag_or_nil/1)
  end

  defp take(attrs, source, fields, cast) do
    Enum.reduce(fields, attrs, fn {column, property}, attrs ->
      Map.put(attrs, column, cast.(source[property]))
    end)
  end

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_), do: nil

  @true_flags ~w[true enabled on yes 1]
  @false_flags ~w[false disabled off no 0]

  defp flag_or_nil(value) when is_boolean(value), do: value

  defp flag_or_nil(value) when is_binary(value) do
    case String.downcase(value) do
      flag when flag in @true_flags -> true
      flag when flag in @false_flags -> false
      _ -> nil
    end
  end

  defp flag_or_nil(_), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp list_or_nil(value) when is_list(value), do: value
  defp list_or_nil(_), do: nil

  defp parse_datetime(value) when value in [nil, ""], do: nil

  # Intune does not omit a timestamp it has no value for, it sends 0001-01-01,
  # which parses fine and would otherwise date a device to year 1.
  #
  # Its other sentinel, 9999-12-31, is kept as a real timestamp. That one means
  # "never expires" rather than "unknown", and holding it as a far future date
  # is what keeps `expires_at > now()` answering true for those devices.
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{year: year}, _offset} when year <= 1 ->
        nil

      {:ok, datetime, _offset} ->
        %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

      _ -> nil
    end
  end

  defp nil_if_blank(value) when value in [nil, ""], do: nil
  defp nil_if_blank(value), do: value

  defp raise_sync_error(provider, step, error) do
    raise Intune.SyncError,
      provider_id: provider.id,
      step: step,
      error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe
    alias Portal.Intune

    def get_provider(account_id, id) do
      from(i in Intune.PostureProvider,
        join: a in Portal.Account,
        on: a.id == i.account_id,
        where: i.account_id == ^account_id,
        where: i.id == ^id,
        where: i.is_disabled == false,
        where: i.is_verified == true,
        where: a.is_disabled == false,
        where: fragment("(?)->>'device_posture' = 'true'", a.features)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def upsert_devices(rows, replace_fields) do
      Safe.unscoped()
      |> Safe.insert_all(Intune.Device, rows,
        conflict_target: [:account_id, :intune_id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(provider, synced_at) do
      from(d in Intune.Device,
        where: d.account_id == ^provider.account_id,
        where: d.posture_provider_id == ^provider.id,
        where: d.synced_at < ^synced_at
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def mark_succeeded(provider, synced_at) do
      provider
      |> Ecto.Changeset.change(%{
        synced_at: synced_at,
        errored_at: nil,
        error_message: nil,
        error_email_count: 0
      })
      |> Safe.unscoped()
      |> Safe.update()
    end
  end
end
