defmodule Portal.SentinelOne.Sync do
  @moduledoc """
  Synchronizes endpoint agents from a SentinelOne Management Console.

  SentinelOne exposes both offset and cursor pagination. This sync deliberately
  orders by agent id and follows `pagination.nextCursor`, avoiding the moving
  offset that can skip an endpoint when another endpoint is removed mid-walk.

  Cursor pagination is still a view of a live collection, so deletion also uses
  the same two database-backed bounds as the other inventory providers: an
  endpoint must not have been seen for a day and must predate the previous
  completed run. One incomplete walk can never delete a live endpoint.
  """

  use Oban.Worker,
    queue: :sentinelone_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.SentinelOne
  alias Portal.SentinelOne.APIClient
  alias __MODULE__.Database

  @stale_after_seconds 24 * 60 * 60

  @replace_fields SentinelOne.Device.__schema__(:fields) --
                    [:account_id, :posture_provider_id, :uuid, :inserted_at]

  @upsert_chunk_size div(65_535, length(SentinelOne.Device.__schema__(:fields)))

  # These tables mirror the AgentView properties in SentinelOne's Management
  # API v2.1 Swagger. Keeping the source names alongside the columns makes
  # schema drift reviewable when SentinelOne publishes a new field.
  # Source verified 2026-08-26:
  # https://github.com/Sentinel-One/ai-siem/blob/main/plugins/s1-secops-skills/skills/mgmt-console-api/spec/swagger_2_1.json
  @text_fields [
    {:sentinelone_id, "id"},
    {:sentinelone_account_id, "accountId"},
    {:account_name, "accountName"},
    {:site_id, "siteId"},
    {:site_name, "siteName"},
    {:group_id, "groupId"},
    {:group_name, "groupName"},
    {:license_key, "licenseKey"},
    {:uuid, "uuid"},
    {:agent_version, "agentVersion"},
    {:domain, "domain"},
    {:computer_name, "computerName"},
    {:os_name, "osName"},
    {:os_revision, "osRevision"},
    {:os_arch, "osArch"},
    {:os_username, "osUsername"},
    {:os_type, "osType"},
    {:model_name, "modelName"},
    {:machine_type, "machineType"},
    {:cpu_id, "cpuId"},
    {:group_ip, "groupIp"},
    {:network_status, "networkStatus"},
    {:last_logged_in_user_name, "lastLoggedInUserName"},
    {:scan_status, "scanStatus"},
    {:mitigation_mode, "mitigationMode"},
    {:mitigation_mode_suspicious, "mitigationModeSuspicious"},
    {:console_migration_status, "consoleMigrationStatus"},
    {:apps_vulnerability_status, "appsVulnerabilityStatus"},
    {:location_type, "locationType"},
    {:external_id, "externalId"},
    {:serial_number, "serialNumber"},
    {:machine_sid, "machineSid"},
    {:installer_type, "installerType"},
    {:ranger_version, "rangerVersion"},
    {:ranger_status, "rangerStatus"},
    {:operational_state, "operationalState"},
    {:remote_profiling_state, "remoteProfilingState"},
    {:storage_type, "storageType"},
    {:storage_name, "storageName"},
    {:detection_state, "detectionState"}
  ]

  @ip_fields [
    {:external_ip, "externalIp"},
    {:last_ip_to_management, "lastIpToMgmt"}
  ]

  @boolean_fields [
    {:infected, "infected"},
    {:threat_reboot_required, "threatRebootRequired"},
    {:is_active, "isActive"},
    {:is_up_to_date, "isUpToDate"},
    {:is_pending_uninstall, "isPendingUninstall"},
    {:is_uninstalled, "isUninstalled"},
    {:is_decommissioned, "isDecommissioned"},
    {:encrypted_applications, "encryptedApplications"},
    {:in_remote_shell_session, "inRemoteShellSession"},
    {:allow_remote_shell, "allowRemoteShell"},
    {:network_quarantine_enabled, "networkQuarantineEnabled"},
    {:firewall_enabled, "firewallEnabled"},
    {:location_enabled, "locationEnabled"},
    {:show_alert_icon, "showAlertIcon"},
    {:has_containerized_workload, "hasContainerizedWorkload"},
    {:is_ad_connector, "isAdConnector"},
    {:is_hyper_automate, "isHyperAutomate"}
  ]

  @integer_fields [
    {:total_memory, "totalMemory"},
    {:cpu_count, "cpuCount"},
    {:core_count, "coreCount"},
    {:active_threats, "activeThreats"}
  ]

  @datetime_fields [
    {:source_created_at, "createdAt"},
    {:source_updated_at, "updatedAt"},
    {:group_updated_at, "groupUpdatedAt"},
    {:policy_updated_at, "policyUpdatedAt"},
    {:os_start_time, "osStartTime"},
    {:last_active_at, "lastActiveDate"},
    {:registered_at, "registeredAt"},
    {:scan_started_at, "scanStartedAt"},
    {:scan_finished_at, "scanFinishedAt"},
    {:scan_aborted_at, "scanAbortedAt"},
    {:full_disk_scan_updated_at, "fullDiskScanLastUpdatedAt"},
    {:operational_state_expires_at, "operationalStateExpiration"},
    {:remote_profiling_state_expires_at, "remoteProfilingStateExpiration"},
    {:first_full_mode_at, "firstFullModeTime"},
    {:last_successful_scan_at, "lastSuccessfulScanDate"}
  ]

  @string_list_fields [
    {:user_actions_needed, "userActionsNeeded"},
    {:missing_permissions, "missingPermissions"},
    {:active_protection, "activeProtection"}
  ]

  @structured_fields ~w[
    activeDirectory cloudProviders containerizedWorkloadCounts locations networkInterfaces
    proxyStates tags
  ]

  @agent_view_properties Enum.map(
                           @text_fields ++
                             @ip_fields ++
                             @boolean_fields ++
                             @integer_fields ++ @datetime_fields ++ @string_list_fields,
                           &elem(&1, 1)
                         ) ++ @structured_fields

  @ad_text_fields [
    {:ad_last_user_distinguished_name, "lastUserDistinguishedName"},
    {:ad_computer_distinguished_name, "computerDistinguishedName"},
    {:ad_user_principal_name, "userPrincipalName"},
    {:ad_mail, "mail"}
  ]

  @ad_string_list_fields [
    {:ad_last_user_member_of, "lastUserMemberOf"},
    {:ad_computer_member_of, "computerMemberOf"}
  ]

  @proxy_text_fields [
    {:proxy_method, "proxyMethod"},
    {:proxy_console_address, "consoleProxyAddress"},
    {:proxy_deep_visibility_address, "deepVisibilityProxyAddress"}
  ]

  @proxy_boolean_fields [
    {:proxy_console, "console"},
    {:proxy_deep_visibility, "deepVisibility"},
    {:proxy_pac_file_usage, "pacFileUsage"}
  ]

  @workload_integer_fields [
    {:protected_pods_count, "podsCount"},
    {:protected_containers_count, "containersCount"},
    {:protected_tasks_count, "tasksCount"}
  ]

  @doc false
  def agent_view_properties, do: @agent_view_properties

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

  defp sync(account_id, provider_id) do
    case Database.get_provider(account_id, provider_id) do
      nil ->
        Logger.info(
          "SentinelOne provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%SentinelOne.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    device_count =
      provider
      |> APIClient.new()
      |> APIClient.stream_agents()
      |> Enum.reduce(0, fn
        agents, count when is_list(agents) ->
          sync_page(provider, agents, started_at)
          count + length(agents)

        {:error, error}, _count ->
          raise_sync_error(provider, :list_agents, error)
      end)

    delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished SentinelOne device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id,
      device_count: device_count
    )

    :ok
  end

  defp delete_stale_devices(%SentinelOne.PostureProvider{synced_at: nil}, _started_at), do: :ok

  defp delete_stale_devices(provider, started_at) do
    cutoff =
      Enum.min([provider.synced_at, DateTime.add(started_at, -@stale_after_seconds)], DateTime)

    Database.delete_stale_devices(provider, cutoff)
  end

  defp sync_page(_provider, [], _started_at), do: :ok

  defp sync_page(provider, agents, started_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    agents
    |> Enum.filter(&has_uuid_or_warn(&1, provider))
    |> Enum.map(fn agent ->
      agent
      |> device_attrs(provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @replace_fields))
  end

  defp has_uuid_or_warn(%{"uuid" => uuid}, _provider)
       when is_binary(uuid) and uuid != "",
       do: true

  defp has_uuid_or_warn(agent, provider) do
    agent = map_or_empty(agent)

    Logger.warning("Skipping SentinelOne agent without a UUID",
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      sentinelone_agent_id: agent["id"],
      computer_name: agent["computerName"],
      serial_number: agent["serialNumber"],
      site_id: agent["siteId"]
    )

    false
  end

  defp device_attrs(agent, provider, synced_at) do
    active_directory = map_or_empty(agent["activeDirectory"])
    proxy_states = map_or_empty(agent["proxyStates"])
    workload_counts = map_or_empty(agent["containerizedWorkloadCounts"])

    %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      network_interfaces: map_list_or_nil(agent["networkInterfaces"]),
      locations: map_list_or_nil(agent["locations"]),
      cloud_providers: map_or_nil(agent["cloudProviders"]),
      tags: sentinelone_tags(agent["tags"]),
      synced_at: synced_at
    }
    |> take(agent, @text_fields, &text_or_nil/1)
    |> take(agent, @ip_fields, &ip_or_nil/1)
    |> take(agent, @boolean_fields, &boolean_or_nil/1)
    |> take(agent, @integer_fields, &integer_or_nil/1)
    |> take(agent, @datetime_fields, &parse_datetime/1)
    |> take(agent, @string_list_fields, &string_list_or_nil/1)
    |> take(active_directory, @ad_text_fields, &text_or_nil/1)
    |> take(active_directory, @ad_string_list_fields, &string_list_or_nil/1)
    |> take(proxy_states, @proxy_text_fields, &text_or_nil/1)
    |> take(proxy_states, @proxy_boolean_fields, &boolean_or_nil/1)
    |> take(workload_counts, @workload_integer_fields, &integer_or_nil/1)
  end

  defp take(attrs, source, fields, cast) do
    Enum.reduce(fields, attrs, fn {column, property}, attrs ->
      Map.put(attrs, column, cast.(source[property]))
    end)
  end

  defp text_or_nil(value) when value in [nil, ""], do: nil
  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_value), do: nil

  defp ip_or_nil(value) when is_binary(value) do
    case Portal.Types.IP.cast(value) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp ip_or_nil(_value), do: nil

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp string_list_or_nil(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp string_list_or_nil(_value), do: nil

  defp map_list_or_nil(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp map_list_or_nil(_value), do: nil

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp sentinelone_tags(%{"sentinelone" => tags}), do: map_list_or_nil(tags)
  defp sentinelone_tags(_value), do: nil

  defp parse_datetime(value) when value in [nil, ""], do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp raise_sync_error(provider, step, error) do
    raise SentinelOne.SyncError, provider_id: provider.id, step: step, error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Safe, SentinelOne}

    def get_provider(account_id, id) do
      from(p in SentinelOne.PostureProvider,
        join: a in Portal.Account,
        on: a.id == p.account_id,
        where: p.account_id == ^account_id,
        where: p.id == ^id,
        where: p.is_disabled == false,
        where: p.is_verified == true,
        where: a.is_disabled == false,
        where: fragment("(?)->>'device_posture' = 'true'", a.features)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def upsert_devices(rows, replace_fields) do
      Safe.unscoped()
      |> Safe.insert_all(SentinelOne.Device, rows,
        conflict_target: [:account_id, :uuid],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(provider, cutoff) do
      from(d in SentinelOne.Device,
        where: d.account_id == ^provider.account_id,
        where: d.posture_provider_id == ^provider.id,
        where: d.synced_at < ^cutoff
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
