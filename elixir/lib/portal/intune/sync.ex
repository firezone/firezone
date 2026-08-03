defmodule Portal.Intune.Sync do
  @moduledoc """
  Synchronizes Intune managed devices and links them to attested Firezone devices.
  """

  use Oban.Worker,
    queue: :intune_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:device_integration_id]]

  import Ecto.Query
  require Logger

  alias Portal.Intune
  alias __MODULE__.Database

  @replace_fields Portal.Intune.Device.__schema__(:fields) --
                    [:id, :account_id, :device_integration_id, :intune_id, :inserted_at]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_integration_id" => integration_id}}) do
    case Database.get_integration(integration_id) do
      nil ->
        Logger.info("Intune integration not found or disabled; skipping sync",
          device_integration_id: integration_id
        )

        :ok

      integration ->
        run_sync(integration)
    end
  end

  defp run_sync(%Intune.Integration{} = integration) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    try do
      access_token = get_access_token!(integration)

      Intune.APIClient.stream_managed_devices(access_token)
      |> Stream.each(fn
        devices when is_list(devices) -> sync_page(integration, devices, started_at)
        {:error, error} -> raise_sync_error(integration, :list_managed_devices, error)
      end)
      |> Stream.run()

      Database.delete_stale_devices(integration, started_at)
      Database.mark_succeeded(integration, started_at)

      Portal.PubSub.Changes.broadcast(
        integration.account_id,
        :device_inventory,
        :device_inventory_changed
      )

      Logger.info("Finished Intune device inventory sync",
        device_integration_id: integration.id,
        account_id: integration.account_id
      )

      :ok
    rescue
      exception ->
        Database.mark_failed(integration, exception)
        reraise exception, __STACKTRACE__
    end
  end

  defp get_access_token!(integration) do
    case Intune.APIClient.get_access_token(integration.tenant_id) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} ->
        access_token

      {:ok, %Req.Response{} = response} ->
        raise_sync_error(integration, :get_access_token, response)

      {:error, error} ->
        raise_sync_error(integration, :get_access_token, error)
    end
  end

  defp sync_page(_integration, [], _started_at), do: :ok

  defp sync_page(integration, graph_devices, started_at) do
    validate_devices!(integration, graph_devices)

    intune_ids = Enum.map(graph_devices, & &1["id"])
    serial_numbers =
      graph_devices
      |> Enum.map(&normalize_serial(&1["serialNumber"]))
      |> Enum.reject(&blank?/1)

    existing = Database.existing_devices(integration, intune_ids) |> Map.new(&{&1.intune_id, &1})
    candidates = Database.matching_firezone_devices(integration.account_id, intune_ids, serial_numbers)
    candidate_indexes = candidate_indexes(candidates)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(graph_devices, fn graph_device ->
        existing_device = Map.get(existing, graph_device["id"])

        graph_device
        |> device_attrs(integration, started_at)
        |> Map.put(:id, existing_device && existing_device.id || Ecto.UUID.generate())
        |> Map.put(
          :device_id,
          matching_device_id(graph_device, candidate_indexes) ||
            (existing_device && existing_device.device_id)
        )
        |> Map.put(:inserted_at, existing_device && existing_device.inserted_at || now)
        |> Map.put(:updated_at, now)
      end)

    Database.upsert_devices(rows, @replace_fields)
  end

  defp validate_devices!(integration, graph_devices) do
    unless Enum.all?(graph_devices, &(is_binary(&1["id"]) and &1["id"] != "")) do
      raise_sync_error(integration, :validate_managed_devices, :missing_device_id)
    end
  end

  defp device_attrs(graph_device, integration, synced_at) do
    %{
      account_id: integration.account_id,
      device_integration_id: integration.id,
      intune_id: graph_device["id"],
      device_name: graph_device["deviceName"],
      managed_device_name: graph_device["managedDeviceName"],
      serial_number: nil_if_blank(graph_device["serialNumber"]),
      entra_device_id: nil_if_blank(graph_device["azureADDeviceId"]),
      user_id: nil_if_blank(graph_device["userId"]),
      user_principal_name: nil_if_blank(graph_device["userPrincipalName"]),
      user_display_name: nil_if_blank(graph_device["userDisplayName"]),
      email_address: nil_if_blank(graph_device["emailAddress"]),
      operating_system: nil_if_blank(graph_device["operatingSystem"]),
      os_version: nil_if_blank(graph_device["osVersion"]),
      model: nil_if_blank(graph_device["model"]),
      manufacturer: nil_if_blank(graph_device["manufacturer"]),
      compliance_state: nil_if_blank(graph_device["complianceState"]),
      management_agent: nil_if_blank(graph_device["managementAgent"]),
      managed_device_owner_type: nil_if_blank(graph_device["managedDeviceOwnerType"]),
      device_enrollment_type: nil_if_blank(graph_device["deviceEnrollmentType"]),
      device_registration_state: nil_if_blank(graph_device["deviceRegistrationState"]),
      partner_reported_threat_state: nil_if_blank(graph_device["partnerReportedThreatState"]),
      jail_broken: nil_if_blank(graph_device["jailBroken"]),
      is_encrypted: graph_device["isEncrypted"],
      is_supervised: graph_device["isSupervised"],
      enrolled_at: parse_datetime(graph_device["enrolledDateTime"]),
      last_sync_at: parse_datetime(graph_device["lastSyncDateTime"]),
      compliance_grace_period_expiration_at:
        parse_datetime(graph_device["complianceGracePeriodExpirationDateTime"]),
      synced_at: synced_at,
      attributes: graph_device
    }
  end

  defp candidate_indexes(candidates) do
    %{
      mdm: group_candidate_ids(candidates, & &1.last_attested_mdm_device_id),
      serial: group_candidate_ids(candidates, &normalize_serial(&1.last_attested_device_serial))
    }
  end

  defp group_candidate_ids(candidates, key_fun) do
    candidates
    |> Enum.reject(&(key_fun.(&1) in [nil, ""]))
    |> Enum.group_by(key_fun, & &1.id)
  end

  defp matching_device_id(graph_device, indexes) do
    unique_candidate(indexes.mdm[graph_device["id"]]) ||
      unique_candidate(indexes.serial[normalize_serial(graph_device["serialNumber"])])
  end

  defp unique_candidate([id]), do: id
  defp unique_candidate(_), do: nil

  defp parse_datetime(value) when value in [nil, ""], do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

      _ -> nil
    end
  end

  defp normalize_serial(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_serial(_), do: nil
  defp blank?(value), do: value in [nil, ""]
  defp nil_if_blank(value) when value in [nil, ""], do: nil
  defp nil_if_blank(value), do: value

  defp raise_sync_error(integration, step, error) do
    raise Intune.SyncError,
      integration_id: integration.id,
      step: step,
      error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Device, Safe}
    alias Portal.Intune

    def get_integration(id) do
      from(i in Intune.Integration,
        join: a in Portal.Account,
        on: a.id == i.account_id,
        where: i.id == ^id,
        where: i.is_disabled == false,
        where: i.is_verified == true,
        where: a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def existing_devices(integration, intune_ids) do
      from(d in Intune.Device,
        where: d.account_id == ^integration.account_id,
        where: d.device_integration_id == ^integration.id,
        where: d.intune_id in ^intune_ids
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def matching_firezone_devices(account_id, intune_ids, serial_numbers) do
      from(d in Device,
        where: d.account_id == ^account_id,
        where: d.type == :client,
        where:
          d.last_attested_mdm_device_id in ^intune_ids or
            fragment("lower(trim(?))", d.last_attested_device_serial) in ^serial_numbers
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def upsert_devices(rows, replace_fields) do
      Safe.unscoped()
      |> Safe.insert_all(Intune.Device, rows,
        conflict_target: [:id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(integration, synced_at) do
      from(d in Intune.Device,
        where: d.account_id == ^integration.account_id,
        where: d.device_integration_id == ^integration.id,
        where: d.synced_at < ^synced_at
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def mark_succeeded(integration, synced_at) do
      integration
      |> Ecto.Changeset.change(%{
        synced_at: synced_at,
        errored_at: nil,
        error_message: nil,
        disabled_reason: nil
      })
      |> Safe.unscoped()
      |> Safe.update()
    end

    def mark_failed(integration, exception) do
      integration
      |> Ecto.Changeset.change(%{
        errored_at: DateTime.utc_now(),
        error_message: Exception.message(exception)
      })
      |> Safe.unscoped()
      |> Safe.update()
    end
  end
end
