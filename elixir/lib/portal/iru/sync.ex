defmodule Portal.Iru.Sync do
  @moduledoc """
  Synchronizes the device list from an Iru (formerly Kandji) tenant.

  The device list is one endpoint and each posture signal is another, so a run
  reads `/api/v1/devices` first and then folds every per-device Prism category
  into the rows it just wrote.

  That list is walked with `limit` and `offset` over a collection that keeps
  changing, so a page boundary can step over a device that was there the whole
  time: anything removed at the source mid-walk pulls the devices after it back
  by one, into a page already read. There is no cursor to follow instead.

  So a device missing from one run is not evidence that it is gone. A run
  deletes a device only once no run has seen it for `@stale_after_seconds`, and
  only if the run before this one did not see it either.

  The first bound rides out a skip, because the run two hours later picks the
  device up again. The second bound covers a sync that has been failing for
  longer than the window: every row is past the clock by then, so without it
  the first run to succeed again could delete most of a tenant on one walk.
  """

  use Oban.Worker,
    queue: :iru_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.Iru
  alias Portal.Iru.APIClient
  alias __MODULE__.Database

  # Twelve runs at the current two-hour schedule. Long enough that a device has
  # to be skipped over and over to be deleted, short enough that a device really
  # removed from the tenant stops counting as known within a day.
  @stale_after_seconds 24 * 60 * 60

  # Postgres binds at most 65535 parameters per statement, so a full page of 300
  # devices has to fit within that. Derived from the field count so adding a
  # column cannot silently overflow it.
  @upsert_chunk_size div(65_535, length(Portal.Iru.Device.__schema__(:fields)))

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
        Logger.info("Iru provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%Iru.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    client = APIClient.new(provider)

    synced_ids = sync_devices(provider, client, started_at)
    sync_prism_categories(provider, client, synced_ids)

    delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished Iru device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id,
      device_count: MapSet.size(synced_ids)
    )

    :ok
  end

  # `synced_at` on the provider is the run before this one, so the earlier of the
  # two bounds is the one to delete against. Nothing has synced yet on a first
  # run, which leaves no earlier run to measure from and nothing to delete.
  defp delete_stale_devices(%Iru.PostureProvider{synced_at: nil}, _started_at), do: :ok

  defp delete_stale_devices(provider, started_at) do
    cutoff =
      Enum.min([provider.synced_at, DateTime.add(started_at, -@stale_after_seconds)], DateTime)

    Database.delete_stale_devices(provider, cutoff)
  end

  # Every property of the `/api/v1/devices` record. `user` is an object on a
  # device with an assigned user and an empty string on one without, so it is
  # flattened by hand rather than through the tables below.
  @device_text_fields [
    {:iru_id, "device_id"},
    {:device_name, "device_name"},
    {:model, "model"},
    {:serial_number, "serial_number"},
    {:platform, "platform"},
    {:os_version, "os_version"},
    {:supplemental_build_version, "supplemental_build_version"},
    {:supplemental_os_version_extra, "supplemental_os_version_extra"},
    {:asset_tag, "asset_tag"},
    {:blueprint_id, "blueprint_id"},
    {:blueprint_name, "blueprint_name"},
    {:agent_version, "agent_version"},
    {:lost_mode_status, "lost_mode_status"}
  ]

  @device_boolean_fields [
    {:mdm_enabled, "mdm_enabled"},
    {:agent_installed, "agent_installed"},
    {:is_missing, "is_missing"},
    {:is_removed, "is_removed"}
  ]

  @device_datetime_fields [
    {:last_check_in_at, "last_check_in"},
    {:first_enrolled_at, "first_enrollment"},
    {:last_enrolled_at, "last_enrollment"}
  ]

  @device_fields Enum.map(
                   @device_text_fields ++ @device_boolean_fields ++ @device_datetime_fields,
                   &elem(&1, 0)
                 ) ++
                   [:user_id, :user_name, :user_email, :user_is_archived, :tags]

  @device_replace_fields (@device_fields -- [:iru_id]) ++
                           [:posture_provider_id, :synced_at, :updated_at]

  # The Prism categories that report one row per device. Each is a separate
  # endpoint and a separate permission on the API token, and each carries its
  # own collection timestamp because a device can report one long after another.
  #
  # The activation lock keys come from the device detail resource; the sample in
  # the Iru API reference for that category shows a device information payload.
  @prism_categories [
    {"device_information", :list_device_information,
     %{
       text: [
         {:device_family, "device__family"},
         {:host_name, "host_name"},
         {:local_hostname, "local_hostname"},
         {:model_name, "model_name"},
         {:model_identifier, "model_identifier"},
         {:cellular_technology, "cellular_technology"},
         {:os_build, "os_build"},
         {:os_name, "os_name"},
         {:display_os_version, "display_os_version"}
       ],
       boolean: [
         {:apple_silicon, "apple_silicon"},
         {:shared_ipad, "shared_ipad"},
         {:data_roaming, "data_roaming"},
         {:hotspot, "hotspot"}
       ],
       float: [{:device_capacity_gb, "device_capacity"}],
       datetime: [{:inventory_collected_at, "last_collected_at"}]
     }},
    {"filevault", :list_filevault,
     %{
       text: [{:filevault_key_type, "key_type"}],
       boolean: [
         {:filevault_enabled, "status"},
         {:filevault_key_escrowed, "key_escrowed"},
         {:filevault_regeneration_needed, "regeneration_needed"}
       ],
       float: [],
       datetime: [
         {:filevault_key_rotation_scheduled_at, "scheduled_key_rotation"},
         {:filevault_collected_at, "last_collected_at"}
       ]
     }},
    {"application_firewall", :list_application_firewall,
     %{
       text: [
         {:firewall_logging_option, "logging_option"},
         {:firewall_version, "version"}
       ],
       boolean: [
         {:firewall_enabled, "status"},
         {:firewall_block_all_incoming, "block_all_incoming"},
         {:firewall_logging, "logging"},
         {:firewall_stealth_mode, "stealth_mode"},
         {:firewall_allow_signed_applications, "allow_signed_applications"},
         {:firewall_unloading, "unloading"}
       ],
       float: [],
       datetime: [{:firewall_collected_at, "last_collected_at"}]
     }},
    {"gatekeeper_and_xprotect", :list_gatekeeper_and_xprotect,
     %{
       text: [
         {:gatekeeper_version, "gatekeeper_version"},
         {:gatekeeper_opaque_version, "gatekeeper_opaque_version"},
         {:xprotect_version, "xprotect_version"},
         {:malware_removal_tool_version, "malware_removal_tool_version"}
       ],
       boolean: [
         {:gatekeeper_enabled, "gatekeeper_status"},
         {:gatekeeper_trusted_developers, "trusted_developers"}
       ],
       float: [],
       datetime: [{:gatekeeper_collected_at, "last_collected_at"}]
     }},
    {"startup_settings", :list_startup_settings,
     %{
       text: [
         {:external_boot_level, "external_boot_level"},
         {:secure_boot_level, "secure_boot_level"}
       ],
       boolean: [
         {:sip_enabled, "sip"},
         {:ssv_enabled, "ssv"},
         {:bootstrap_token_auth, "bootstrap_token_auth"},
         {:bootstrap_token_escrowed, "bootstrap_token_escrowed"},
         {:kext_requires_bootstrap_token, "kext_requires_bst"},
         {:software_update_requires_bootstrap_token, "software_update_requires_bst"},
         {:any_signed_os, "any_signed_os"},
         {:mdm_manages_kext, "mdm_manages_kext"},
         {:user_manages_kext, "user_manages_kext"}
       ],
       float: [],
       datetime: [{:startup_settings_collected_at, "last_collected_at"}]
     }},
    {"activation_lock", :list_activation_lock,
     %{
       text: [],
       boolean: [
         {:activation_lock_supported, "activation_lock_supported"},
         {:activation_lock_allowed_while_supervised,
          "activation_lock_allowed_while_supervised"},
         {:device_activation_lock_enabled, "device_activation_lock_enabled"},
         {:user_activation_lock_enabled, "user_activation_lock_enabled"},
         {:activation_lock_bypass_code_failed, "bypass_code_failed"}
       ],
       float: [],
       datetime: [{:activation_lock_collected_at, "last_collected_at"}]
     }}
  ]

  @prism_clear_fields Map.new(@prism_categories, fn {category, _step, mapping} ->
                        fields =
                          mapping
                          |> Map.values()
                          |> List.flatten()
                          |> Enum.map(&elem(&1, 0))

                        {category, fields}
                      end)

  @prism_replace_fields Map.new(@prism_categories, fn {category, _step, mapping} ->
                          fields =
                            mapping
                            |> Map.values()
                            |> List.flatten()
                            |> Enum.map(&elem(&1, 0))

                          {category, fields ++ [:updated_at]}
                        end)

  defp sync_devices(provider, client, started_at) do
    APIClient.stream_devices(client)
    |> Enum.reduce(MapSet.new(), fn
      devices, synced_ids when is_list(devices) ->
        sync_device_page(provider, devices, started_at)
        Enum.reduce(devices, synced_ids, &MapSet.put(&2, &1["device_id"]))

      {:error, error}, _synced_ids ->
        raise_sync_error(provider, :list_devices, error)
    end)
  end

  defp sync_device_page(_provider, [], _started_at), do: :ok

  defp sync_device_page(provider, devices, started_at) do
    validate_devices!(provider, devices)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    devices
    |> Enum.map(fn device ->
      device
      |> device_attrs(provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @device_replace_fields))
  end

  defp validate_devices!(provider, devices) do
    unless Enum.all?(devices, &(is_binary(&1["device_id"]) and &1["device_id"] != "")) do
      raise_sync_error(provider, :validate_devices, :missing_device_id)
    end
  end

  defp device_attrs(device, provider, synced_at) do
    %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      tags: list_of_strings_or_nil(device["tags"]),
      synced_at: synced_at
    }
    |> Map.merge(user_attrs(device["user"]))
    |> take(device, @device_text_fields, &nil_if_blank/1)
    |> take(device, @device_boolean_fields, &boolean_or_nil/1)
    |> take(device, @device_datetime_fields, &parse_datetime/1)
  end

  defp user_attrs(user) when is_map(user) do
    %{
      user_id: nil_if_blank(user["id"]),
      user_name: nil_if_blank(user["name"]),
      user_email: nil_if_blank(user["email"]),
      user_is_archived: boolean_or_nil(user["is_archived"])
    }
  end

  defp user_attrs(_user) do
    %{user_id: nil, user_name: nil, user_email: nil, user_is_archived: nil}
  end

  @doc """
  The Prism categories a run reads, in the order it reads them.
  """
  def prism_categories, do: Enum.map(@prism_categories, &elem(&1, 0))

  defp sync_prism_categories(provider, client, synced_ids) do
    Enum.each(@prism_categories, &sync_prism_category(provider, client, &1, synced_ids))
  end

  # A category the token cannot read costs that category rather than the whole
  # run: Iru scopes API token permissions per endpoint, and Prism is not part of
  # every subscription, so a fleet with no FileVault visibility still deserves
  # its device list.
  defp sync_prism_category(provider, client, {category, step, mapping}, synced_ids) do
    replace_fields = Map.fetch!(@prism_replace_fields, category)

    reported =
      APIClient.stream_prism(client, category)
      |> Enum.reduce(MapSet.new(), fn
        rows, reported when is_list(rows) ->
          sync_prism_page(provider, rows, mapping, replace_fields, synced_ids)
          Enum.reduce(rows, reported, &MapSet.put(&2, &1["device_id"]))

        {:error, %Req.Response{status: status}}, _reported when status in [403, 404] ->
          Logger.info("Iru refused a Prism category, clearing the fields it reports",
            posture_provider_id: provider.id,
            account_id: provider.account_id,
            category: category,
            status: status
          )

          :refused

        {:error, error}, _reported ->
          raise_sync_error(provider, step, error)
      end)

    clear_unreported(provider, category, synced_ids, reported)
  end

  # Posture nobody reports any more must not read as current: a revoked
  # permission, a dropped subscription or a device a category stopped covering
  # all leave the columns behind, and a stale FileVault or firewall answer is
  # worse than no answer.
  defp clear_unreported(provider, category, _synced_ids, :refused) do
    Database.clear_prism_fields(provider, Map.fetch!(@prism_clear_fields, category))
  end

  defp clear_unreported(provider, category, synced_ids, reported) do
    case synced_ids |> MapSet.difference(reported) |> MapSet.to_list() do
      [] ->
        :ok

      unreported ->
        Database.clear_prism_fields(
          provider,
          Map.fetch!(@prism_clear_fields, category),
          unreported
        )
    end
  end

  defp sync_prism_page(provider, rows, mapping, replace_fields, synced_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows
    |> Enum.filter(&MapSet.member?(synced_ids, &1["device_id"]))
    |> Enum.map(fn row ->
      %{
        account_id: provider.account_id,
        posture_provider_id: provider.id,
        iru_id: row["device_id"],
        synced_at: now,
        inserted_at: now,
        updated_at: now
      }
      |> take(row, mapping.text, &nil_if_blank/1)
      |> take(row, mapping.boolean, &boolean_or_nil/1)
      |> take(row, mapping.float, &float_or_nil/1)
      |> take(row, mapping.datetime, &parse_datetime/1)
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, replace_fields))
  end

  defp take(attrs, source, fields, cast) do
    Enum.reduce(fields, attrs, fn {column, property}, attrs ->
      Map.put(attrs, column, cast.(source[property]))
    end)
  end

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_), do: nil

  defp float_or_nil(value) when is_float(value), do: value
  defp float_or_nil(value) when is_integer(value), do: value * 1.0
  defp float_or_nil(_), do: nil

  defp list_of_strings_or_nil(value) when is_list(value) do
    Enum.filter(value, &is_binary/1)
  end

  defp list_of_strings_or_nil(_), do: nil

  defp parse_datetime(value) when value in [nil, ""], do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

      _ ->
        nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp nil_if_blank(value) when value in [nil, ""], do: nil
  defp nil_if_blank(value) when is_binary(value), do: value
  defp nil_if_blank(_value), do: nil

  defp raise_sync_error(provider, step, error) do
    raise Iru.SyncError,
      provider_id: provider.id,
      step: step,
      error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe
    alias Portal.Iru

    # One id per bind, well inside what Postgres accepts for one statement.
    @clear_chunk_size 10_000

    def get_provider(account_id, id) do
      from(p in Iru.PostureProvider,
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
      |> Safe.insert_all(Iru.Device, rows,
        conflict_target: [:account_id, :iru_id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def clear_prism_fields(provider, fields) do
      provider
      |> devices_query()
      |> Safe.unscoped()
      |> Safe.update_all(set: cleared(fields))
    end

    def clear_prism_fields(provider, fields, iru_ids) do
      iru_ids
      |> Enum.chunk_every(@clear_chunk_size)
      |> Enum.each(fn chunk ->
        provider
        |> devices_query()
        |> where([d], d.iru_id in ^chunk)
        |> Safe.unscoped()
        |> Safe.update_all(set: cleared(fields))
      end)
    end

    defp devices_query(provider) do
      from(d in Iru.Device,
        where: d.account_id == ^provider.account_id,
        where: d.posture_provider_id == ^provider.id
      )
    end

    defp cleared(fields) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Enum.map(fields, &{&1, nil}) ++ [updated_at: now]
    end

    def delete_stale_devices(provider, cutoff) do
      from(d in Iru.Device,
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
