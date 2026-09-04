defmodule Portal.Santa.Sync do
  @moduledoc """
  Synchronizes Santa hosts from a North Pole Security Workshop tenant.

  Workshop walks hosts with numbered pages rather than a server-side cursor.
  Ordering by UUID makes the walk deterministic, but a host removed during the
  walk can still shift a later host across a page boundary. Consequently, one
  missed run is not enough evidence to delete a device.

  Stale deletion uses two database-backed bounds: a device must not have been
  seen for `@stale_after_seconds`, and it must predate the last run that fully
  completed. This also keeps the first successful run after a long outage from
  treating one possibly incomplete view of the tenant as authoritative.
  """

  use Oban.Worker,
    queue: :santa_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.Santa
  alias Portal.Santa.APIClient
  alias __MODULE__.Database

  # Twelve runs at the current two-hour schedule. This rides out an occasional
  # page-boundary skip while removing hosts absent from Workshop within a day.
  @stale_after_seconds 24 * 60 * 60

  @replace_fields Santa.Device.__schema__(:fields) --
                    [:account_id, :id, :posture_provider_id, :santa_id, :inserted_at]

  @upsert_chunk_size div(65_535, length(Santa.Device.__schema__(:fields)))

  @text_fields [
    {:santa_id, "uuid"},
    {:serial_number, "serial"},
    {:machine_model, "machineModel"},
    {:hostname, "hostname"},
    {:os_version, "osVersion"},
    {:os_build, "osBuild"},
    {:os_type, "osType"},
    {:primary_user, "primaryUser"},
    {:santa_version, "santaVersion"},
    {:santanetd_version, "santanetdVersion"},
    {:last_seen_client_mode, "lastSeenClientMode"},
    {:configured_client_mode, "configuredClientMode"},
    {:temporary_admin_mode_user, "temporaryAdminModeUser"}
  ]

  @boolean_fields [
    {:primary_user_locked, "primaryUserLocked"},
    {:tags_locked, "tagsLocked"},
    {:tags_truncated, "tagsTruncated"}
  ]

  @string_list_fields [
    {:primary_user_groups, "primaryUserGroups"},
    {:tags, "tags"}
  ]

  @datetime_fields [
    {:last_sync_at, "lastSync"},
    {:rule_sync_at, "ruleSyncTime"},
    {:last_preflight_at, "lastPreflightTime"},
    {:temporary_monitor_mode_ends_at, "temporaryMonitorModeEndTime"},
    {:first_seen_at, "createdAt"},
    {:temporary_admin_mode_ends_at, "temporaryAdminModeEndTime"}
  ]

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
        Logger.info("Santa provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%Santa.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    device_count =
      provider
      |> APIClient.new()
      |> APIClient.stream_hosts()
      |> Enum.reduce(0, fn
        hosts, count when is_list(hosts) ->
          sync_page(provider, hosts, started_at)
          count + length(hosts)

        {:error, error}, _count ->
          raise_sync_error(provider, :list_hosts, error)
      end)

    delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished Santa device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id,
      device_count: device_count
    )

    :ok
  end

  # `provider.synced_at` is the run before this one. On a provider's first run
  # there is no earlier completed inventory to compare, so nothing is deleted.
  defp delete_stale_devices(%Santa.PostureProvider{synced_at: nil}, _started_at), do: :ok

  defp delete_stale_devices(provider, started_at) do
    cutoff =
      Enum.min([provider.synced_at, DateTime.add(started_at, -@stale_after_seconds)], DateTime)

    Database.delete_stale_devices(provider, cutoff)
  end

  defp sync_page(_provider, [], _started_at), do: :ok

  defp sync_page(provider, hosts, started_at) do
    validate_hosts!(provider, hosts)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    hosts
    |> Enum.map(fn host ->
      host
      |> device_attrs(provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @replace_fields))
  end

  defp validate_hosts!(provider, hosts) do
    unless Enum.all?(hosts, &(is_map(&1) and is_binary(&1["uuid"]) and &1["uuid"] != "")) do
      raise_sync_error(provider, :validate_hosts, :missing_host_id)
    end
  end

  defp device_attrs(host, provider, synced_at) do
    %{
      account_id: provider.account_id,
      id: Ecto.UUID.generate(),
      posture_provider_id: provider.id,
      synced_at: synced_at
    }
    |> Map.put(:last_preflight_ip, ip_or_nil(host["lastPreflightIp"]))
    |> Map.put(:sip_status, sip_status(host))
    |> take(host, @text_fields, &nil_if_blank/1)
    |> take(host, @boolean_fields, &boolean_or_false/1)
    |> take(host, @string_list_fields, &string_list_or_nil/1)
    |> take(host, @datetime_fields, &parse_datetime/1)
  end

  defp take(attrs, source, fields, cast) do
    Enum.reduce(fields, attrs, fn {column, property}, attrs ->
      Map.put(attrs, column, cast.(source[property]))
    end)
  end

  defp nil_if_blank(value) when value in [nil, ""], do: nil
  defp nil_if_blank(value) when is_binary(value), do: value
  defp nil_if_blank(_value), do: nil

  # ProtoJSON omits fields at their default, so a missing bool is false and a
  # missing sipStatus on a Mac is 0, meaning SIP is fully enabled.
  defp boolean_or_false(value) when is_boolean(value), do: value
  defp boolean_or_false(_value), do: false

  defp sip_status(%{"sipStatus" => status}) when is_integer(status), do: status
  defp sip_status(%{"osType" => "OS_TYPE_MACOS"}), do: 0
  defp sip_status(_host), do: nil

  # The host proto types the address as bytes, which ProtoJSON base64-encodes.
  defp ip_or_nil(value) when is_binary(value) do
    with {:ok, bytes} <- Base.decode64(value),
         {:ok, ip} <- Portal.Types.IP.cast(bytes_to_address(bytes)) do
      ip
    else
      _ -> nil
    end
  end

  defp ip_or_nil(_value), do: nil

  defp bytes_to_address(<<a, b, c, d>>), do: {a, b, c, d}

  defp bytes_to_address(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h}

  defp bytes_to_address(_bytes), do: nil

  defp string_list_or_nil(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp string_list_or_nil(_value), do: nil

  defp parse_datetime(value) when value in [nil, ""], do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp raise_sync_error(provider, step, error) do
    raise Santa.SyncError, provider_id: provider.id, step: step, error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Safe, Santa}

    def get_provider(account_id, id) do
      from(p in Santa.PostureProvider,
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
      |> Safe.insert_all(Santa.Device, rows,
        conflict_target: [:account_id, :posture_provider_id, :santa_id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(provider, cutoff) do
      from(d in Santa.Device,
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
