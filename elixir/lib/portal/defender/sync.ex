defmodule Portal.Defender.Sync do
  @moduledoc """
  Synchronizes the machine list from a Microsoft Defender for Endpoint tenant.

  Machines are walked with `$skip` over a collection that keeps changing, so a
  page boundary can step over a machine that was there the whole time: anything
  removed at the source mid-walk pulls the machines after it back by one, into
  a page already read. The Graph syncs follow a server-side cursor, which has no
  offset to slide, but this endpoint hands back no cursor to follow.

  So a machine missing from one run is not evidence that it is gone. A run
  deletes a machine only once no run has seen it for `@stale_after_seconds`,
  and only if the run before this one did not see it either.

  The first bound rides out a skip, because the run two hours later picks the
  machine up again. The second bound covers a sync that has been failing for
  longer than the window: every row is past the clock by then, so without it
  the first run to succeed again could delete most of a tenant on one walk.
  """

  use Oban.Worker,
    queue: :defender_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.Defender
  alias Portal.Defender.APIClient
  alias __MODULE__.Database

  @replace_fields Portal.Defender.Device.__schema__(:fields) --
                    [:account_id, :posture_provider_id, :defender_id, :inserted_at]

  # Twelve runs at the current two-hour schedule. Long enough that a machine has
  # to be skipped over and over to be deleted, short enough that a machine
  # really offboarded from the tenant stops counting as known within a day.
  @stale_after_seconds 24 * 60 * 60

  # Postgres binds at most 65535 parameters per statement and a device carries a
  # column per machine property, so a large page would not fit in one insert.
  # Derived from the field count so adding a column cannot silently overflow it.
  @upsert_chunk_size div(65_535, length(Portal.Defender.Device.__schema__(:fields)))

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
        Logger.info("Defender provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%Defender.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    access_token = get_access_token!(provider)

    APIClient.stream_machines(access_token)
    |> Stream.each(fn
      machines when is_list(machines) -> sync_page(provider, machines, started_at)
      {:error, error} -> raise_sync_error(provider, :list_machines, error)
    end)
    |> Stream.run()

    delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished Defender device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id
    )

    :ok
  end

  # `synced_at` on the provider is the run before this one, so the earlier of the
  # two bounds is the one to delete against. Nothing has synced yet on a first
  # run, which leaves no earlier run to measure from and nothing to delete.
  defp delete_stale_devices(%Defender.PostureProvider{synced_at: nil}, _started_at), do: :ok

  defp delete_stale_devices(provider, started_at) do
    cutoff =
      Enum.min([provider.synced_at, DateTime.add(started_at, -@stale_after_seconds)], DateTime)

    Database.delete_stale_devices(provider, cutoff)
  end

  defp get_access_token!(provider) do
    case APIClient.get_access_token(provider.tenant_id) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} ->
        access_token

      {:ok, %Req.Response{} = response} ->
        raise_sync_error(provider, :get_access_token, response)

      {:error, error} ->
        raise_sync_error(provider, :get_access_token, error)
    end
  end

  defp sync_page(_provider, [], _started_at), do: :ok

  defp sync_page(provider, machines, started_at) do
    validate_machines!(provider, machines)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    machines
    |> Enum.map(fn machine ->
      machine
      |> device_attrs(provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @replace_fields))
  end

  defp validate_machines!(provider, machines) do
    unless Enum.all?(machines, &(is_binary(&1["id"]) and &1["id"] != "")) do
      raise_sync_error(provider, :validate_machines, :missing_device_id)
    end
  end

  # Every property the machines endpoint reports, so the two can be diffed by
  # eye when Microsoft adds a field.
  @text_fields [
    {:defender_id, "id"},
    {:computer_dns_name, "computerDnsName"},
    {:os_platform, "osPlatform"},
    {:version, "version"},
    {:os_processor, "osProcessor"},
    {:os_architecture, "osArchitecture"},
    {:agent_version, "agentVersion"},
    {:health_status, "healthStatus"},
    {:onboarding_status, "onboardingStatus"},
    {:managed_by, "managedBy"},
    {:managed_by_status, "managedByStatus"},
    {:risk_score, "riskScore"},
    {:exposure_level, "exposureLevel"},
    {:device_value, "deviceValue"},
    {:rbac_group_name, "rbacGroupName"},
    {:entra_device_id, "aadDeviceId"},
    {:merged_into_machine_id, "mergedIntoMachineId"},
    {:exclusion_reason, "exclusionReason"}
  ]

  @ip_fields [
    {:last_ip_address, "lastIpAddress"},
    {:last_external_ip_address, "lastExternalIpAddress"}
  ]

  @boolean_fields [
    {:entra_joined, "isAadJoined"},
    {:is_potential_duplication, "isPotentialDuplication"},
    {:is_excluded, "isExcluded"}
  ]

  @datetime_fields [
    {:first_seen_at, "firstSeen"},
    {:last_seen_at, "lastSeen"}
  ]

  @vm_metadata_fields [
    {:vm_id, "vmId"},
    {:vm_cloud_provider, "cloudProvider"},
    {:vm_resource_id, "resourceId"},
    {:vm_subscription_id, "subscriptionId"}
  ]

  defp device_attrs(machine, provider, synced_at) do
    # The service's own EDM schema calls this `vmMetadata`, while Elastic's
    # client reads `vm_metadata`. Accept either rather than silently storing
    # nothing, since we have no live tenant to settle it against.
    vm_metadata = machine["vmMetadata"] || machine["vm_metadata"] || %{}

    %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      os_build: integer_or_nil(machine["osBuild"]),
      rbac_group_id: integer_or_nil(machine["rbacGroupId"]),
      machine_tags: string_list_or_nil(machine["machineTags"]),
      ip_addresses: map_list_or_nil(machine["ipAddresses"]),
      synced_at: synced_at
    }
    |> take(machine, @text_fields, &text_or_nil/1)
    |> take(machine, @boolean_fields, &boolean_or_nil/1)
    |> take(machine, @ip_fields, &ip_or_nil/1)
    |> take(machine, @datetime_fields, &parse_datetime/1)
    |> take(vm_metadata, @vm_metadata_fields, &text_or_nil/1)
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

  defp ip_or_nil(value) when is_binary(value) do
    case Portal.Types.IP.cast(value) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp ip_or_nil(_), do: nil

  defp string_list_or_nil(value) when is_list(value) do
    Enum.filter(value, &is_binary/1)
  end

  defp string_list_or_nil(_), do: nil

  defp map_list_or_nil(value) when is_list(value) do
    Enum.filter(value, &is_map/1)
  end

  defp map_list_or_nil(_), do: nil

  defp parse_datetime(value) when value in [nil, ""], do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{year: year}, _offset} when year <= 1 ->
        nil

      {:ok, datetime, _offset} ->
        %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

      _ ->
        nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp text_or_nil(value) when value in [nil, ""], do: nil
  defp text_or_nil(value) when is_binary(value), do: value

  defp text_or_nil(_value), do: nil

  defp raise_sync_error(provider, step, error) do
    raise Defender.SyncError,
      provider_id: provider.id,
      step: step,
      error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe
    alias Portal.Defender

    def get_provider(account_id, id) do
      from(p in Defender.PostureProvider,
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
      |> Safe.insert_all(Defender.Device, rows,
        conflict_target: [:account_id, :defender_id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(provider, cutoff) do
      from(d in Defender.Device,
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
