defmodule Portal.GoogleEndpoint.Sync do
  @moduledoc """
  Synchronizes devices from Google Endpoint Management.

  Pages are walked by token, which is still a view of a live collection, so
  deletion uses the same two bounds as the other inventory providers: a
  device must not have been seen for a day and must predate the previous
  completed run. One incomplete walk can never delete a live device.
  """

  use Oban.Worker,
    queue: :google_endpoint_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.GoogleEndpoint
  alias Portal.GoogleEndpoint.APIClient
  alias __MODULE__.Database

  @stale_after_seconds 24 * 60 * 60

  @replace_fields GoogleEndpoint.Device.__schema__(:fields) --
                    [:account_id, :posture_provider_id, :google_id, :inserted_at]

  @upsert_chunk_size div(65_535, length(GoogleEndpoint.Device.__schema__(:fields)))

  # The Device resource of the Cloud Identity API v1, with its source names
  # next to the columns so a new field shows up in review.
  # Source verified 2026-11-01:
  # https://cloud.google.com/identity/docs/reference/rest/v1/devices
  @text_fields [
    {:device_id, "deviceId"},
    {:unified_device_id, "unifiedDeviceId"},
    {:device_type, "deviceType"},
    {:owner_type, "ownerType"},
    {:management_state, "managementState"},
    {:compromised_state, "compromisedState"},
    {:encryption_state, "encryptionState"},
    {:model, "model"},
    {:manufacturer, "manufacturer"},
    {:brand, "brand"},
    {:hostname, "hostname"},
    {:os_version, "osVersion"},
    {:release_version, "releaseVersion"},
    {:build_number, "buildNumber"},
    {:kernel_version, "kernelVersion"},
    {:baseband_version, "basebandVersion"},
    {:bootloader_version, "bootloaderVersion"},
    {:serial_number, "serialNumber"},
    {:asset_tag, "assetTag"},
    {:imei, "imei"},
    {:meid, "meid"},
    {:network_operator, "networkOperator"}
  ]

  @datetime_fields [
    {:security_patch_at, "securityPatchTime"},
    {:registered_at, "createTime"},
    {:last_sync_at, "lastSyncTime"}
  ]

  @boolean_fields [
    {:enabled_developer_options, "enabledDeveloperOptions"},
    {:enabled_usb_debugging, "enabledUsbDebugging"}
  ]

  @string_list_fields [
    {:wifi_mac_addresses, "wifiMacAddresses"},
    {:other_accounts, "otherAccounts"}
  ]

  @android_text_fields [
    {:android_ownership_privilege, "ownershipPrivilege"}
  ]

  @android_boolean_fields [
    {:android_enabled_unknown_sources, "enabledUnknownSources"},
    {:android_supports_work_profile, "supportsWorkProfile"},
    {:android_owner_profile_account, "ownerProfileAccount"},
    {:android_verified_boot, "verifiedBoot"},
    {:android_cts_profile_match, "ctsProfileMatch"},
    {:android_verify_apps_enabled, "verifyAppsEnabled"},
    {:android_has_potentially_harmful_apps, "hasPotentiallyHarmfulApps"}
  ]

  @nested_objects ~w[name androidSpecificAttributes endpointVerificationSpecificAttributes]

  @device_properties Enum.map(
                       @text_fields ++
                         @datetime_fields ++ @boolean_fields ++ @string_list_fields,
                       &elem(&1, 1)
                     ) ++ @nested_objects

  @doc false
  def device_properties, do: @device_properties

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"account_id" => account_id, "posture_provider_id" => provider_id}
      }) do
    sync(account_id, provider_id)
  end

  def perform(_), do: :ok

  defp sync(account_id, provider_id) do
    case Database.get_provider(account_id, provider_id) do
      nil ->
        Logger.info(
          "Google Endpoint provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%GoogleEndpoint.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    access_token = get_access_token!(provider)

    device_count =
      access_token
      |> APIClient.stream_devices()
      |> Enum.reduce(0, fn
        devices, count when is_list(devices) ->
          sync_page(provider, devices, started_at)
          count + length(devices)

        {:error, error}, _count ->
          raise_sync_error(provider, :list_devices, error)
      end)

    delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished Google Endpoint device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id,
      device_count: device_count
    )

    :ok
  end

  defp get_access_token!(provider) do
    case APIClient.get_access_token(provider.impersonation_email) do
      {:ok, access_token} -> access_token
      {:error, error} -> raise_sync_error(provider, :get_access_token, error)
    end
  end

  defp delete_stale_devices(%GoogleEndpoint.PostureProvider{synced_at: nil}, _started_at), do: :ok

  defp delete_stale_devices(provider, started_at) do
    cutoff =
      Enum.min([provider.synced_at, DateTime.add(started_at, -@stale_after_seconds)], DateTime)

    Database.delete_stale_devices(provider, cutoff)
  end

  defp sync_page(_provider, [], _started_at), do: :ok

  defp sync_page(provider, devices, started_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    devices
    |> Enum.flat_map(&with_google_id(&1, provider))
    |> Enum.map(fn {google_id, device} ->
      device
      |> device_attrs(google_id, provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.uniq_by(& &1.google_id)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @replace_fields))
  end

  # The resource name is `devices/{device}`; the part after the slash is the
  # only identifier every device has.
  defp with_google_id(%{"name" => "devices/" <> google_id} = device, _provider)
       when google_id != "",
       do: [{google_id, device}]

  defp with_google_id(device, provider) do
    device = map_or_empty(device)

    Logger.warning("Skipping Google Endpoint device without a resource name",
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      device_type: device["deviceType"]
    )

    []
  end

  defp device_attrs(device, google_id, provider, synced_at) do
    android = map_or_empty(device["androidSpecificAttributes"])

    %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      google_id: google_id,
      endpoint_verification_attributes: map_or_nil(device["endpointVerificationSpecificAttributes"]),
      synced_at: synced_at
    }
    |> take(device, @text_fields, &text_or_nil/1)
    |> take(device, @boolean_fields, &boolean_or_nil/1)
    |> take(device, @string_list_fields, &string_list_or_nil/1)
    |> take(device, @datetime_fields, &parse_datetime/1)
    |> take(android, @android_text_fields, &text_or_nil/1)
    |> take(android, @android_boolean_fields, &boolean_or_nil/1)
  end

  defp take(attrs, source, fields, cast) do
    Enum.reduce(fields, attrs, fn {column, property}, attrs ->
      Map.put(attrs, column, cast.(source[property]))
    end)
  end

  defp text_or_nil(value) when value in [nil, ""], do: nil
  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_value), do: nil

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp string_list_or_nil(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp string_list_or_nil(_value), do: nil

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp raise_sync_error(provider, step, error) do
    raise GoogleEndpoint.SyncError, provider_id: provider.id, step: step, error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{GoogleEndpoint, Safe}

    def get_provider(account_id, id) do
      from(p in GoogleEndpoint.PostureProvider,
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
      |> Safe.insert_all(GoogleEndpoint.Device, rows,
        conflict_target: [:account_id, :google_id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(provider, cutoff) do
      from(d in GoogleEndpoint.Device,
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
