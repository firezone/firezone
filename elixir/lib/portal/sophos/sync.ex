defmodule Portal.Sophos.Sync do
  @moduledoc """
  Synchronizes endpoints from a Sophos Central tenant.

  Pages are walked by key, which is still a view of a live collection, so
  deletion uses the same two bounds as the other inventory providers: an
  endpoint must not have been seen for a day and must predate the previous
  completed run. One incomplete walk can never delete a live endpoint.
  """

  use Oban.Worker,
    queue: :sophos_sync,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:posture_provider_id]]

  require Logger

  alias Portal.Sophos
  alias Portal.Sophos.APIClient
  alias __MODULE__.Database

  @stale_after_seconds 24 * 60 * 60

  @replace_fields Sophos.Device.__schema__(:fields) --
                    [:account_id, :posture_provider_id, :sophos_id, :inserted_at]

  @upsert_chunk_size div(65_535, length(Sophos.Device.__schema__(:fields)))

  # The Endpoint object of the Endpoint API v1 spec, with its source names
  # next to the columns so a new field shows up in review.
  # Source verified 2026-09-29 (spec 1.72.0):
  # https://developer.sophos.com/assets/specs/endpoint-v1.yaml
  @text_fields [
    {:sophos_id, "id"},
    {:type, "type"},
    {:hostname, "hostname"},
    {:serial_number, "serialNumber"}
  ]

  @datetime_fields [
    {:last_seen_at, "lastSeenAt"},
    {:last_os_update_at, "lastOsUpdateAt"},
    {:last_agent_update_at, "lastAgentUpdateAt"}
  ]

  @boolean_fields [
    {:tamper_protection_supported, "tamperProtectionSupported"},
    {:tamper_protection_enabled, "tamperProtectionEnabled"},
    {:online, "online"},
    {:cloned, "cloned"}
  ]

  @string_list_fields [
    {:ipv4_addresses, "ipv4Addresses"},
    {:ipv6_addresses, "ipv6Addresses"},
    {:mac_addresses, "macAddresses"}
  ]

  @map_list_fields [
    {:group_hierarchy, "groupHierarchy"},
    {:assigned_products, "assignedProducts"},
    {:tags, "tags"}
  ]

  @map_fields [
    {:packages, "packages"},
    {:device_software, "deviceSoftware"}
  ]

  @nested_objects ~w[tenant health os group associatedPerson encryption lockdown cloud isolation]

  @endpoint_properties Enum.map(
                         @text_fields ++
                           @datetime_fields ++
                           @boolean_fields ++ @string_list_fields ++ @map_list_fields ++ @map_fields,
                         &elem(&1, 1)
                       ) ++ @nested_objects

  @os_fields [
    {:os_is_server, "isServer", :boolean},
    {:os_platform, "platform", :text},
    {:os_name, "name", :text},
    {:os_major_version, "majorVersion", :integer},
    {:os_minor_version, "minorVersion", :integer},
    {:os_build, "build", :integer}
  ]

  @doc false
  def endpoint_properties, do: @endpoint_properties

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
        Logger.info("Sophos provider not found, disabled, or account ineligible; skipping sync",
          account_id: account_id,
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        run_sync(provider)
    end
  end

  defp run_sync(%Sophos.PostureProvider{} = provider) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    access_token = get_access_token!(provider)
    tenant = %{tenant_id: provider.tenant_id, data_region_url: provider.data_region_url}

    device_count =
      access_token
      |> APIClient.stream_endpoints(tenant)
      |> Enum.reduce(0, fn
        endpoints, count when is_list(endpoints) ->
          sync_page(provider, endpoints, started_at)
          count + length(endpoints)

        {:error, error}, _count ->
          raise_sync_error(provider, :list_endpoints, error)
      end)

    delete_stale_devices(provider, started_at)
    Database.mark_succeeded(provider, started_at)

    Logger.info("Finished Sophos device inventory sync",
      posture_provider_id: provider.id,
      account_id: provider.account_id,
      device_count: device_count
    )

    :ok
  end

  defp get_access_token!(provider) do
    case APIClient.get_access_token(provider.client_id, provider.client_secret) do
      {:ok, access_token} -> access_token
      {:error, error} -> raise_sync_error(provider, :get_access_token, error)
    end
  end

  defp delete_stale_devices(%Sophos.PostureProvider{synced_at: nil}, _started_at), do: :ok

  defp delete_stale_devices(provider, started_at) do
    cutoff =
      Enum.min([provider.synced_at, DateTime.add(started_at, -@stale_after_seconds)], DateTime)

    Database.delete_stale_devices(provider, cutoff)
  end

  defp sync_page(_provider, [], _started_at), do: :ok

  defp sync_page(provider, endpoints, started_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    endpoints
    |> Enum.filter(&has_id_or_warn(&1, provider))
    |> Enum.map(fn endpoint ->
      endpoint
      |> device_attrs(provider, started_at)
      |> Map.merge(%{inserted_at: now, updated_at: now})
    end)
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.each(&Database.upsert_devices(&1, @replace_fields))
  end

  defp has_id_or_warn(%{"id" => id}, _provider) when is_binary(id) and id != "", do: true

  defp has_id_or_warn(endpoint, provider) do
    endpoint = map_or_empty(endpoint)

    Logger.warning("Skipping Sophos endpoint without an id",
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      hostname: endpoint["hostname"]
    )

    false
  end

  defp device_attrs(endpoint, provider, synced_at) do
    health = map_or_empty(endpoint["health"])
    services = map_or_empty(health["services"])
    os = map_or_empty(endpoint["os"])
    group = map_or_empty(endpoint["group"])
    person = map_or_empty(endpoint["associatedPerson"])
    encryption = map_or_empty(endpoint["encryption"])
    cloud = map_or_empty(endpoint["cloud"])
    isolation = map_or_empty(endpoint["isolation"])

    attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      sophos_tenant_id: text_or_nil(map_or_empty(endpoint["tenant"])["id"]),
      health_overall: text_or_nil(health["overall"]),
      health_threats_status: text_or_nil(map_or_empty(health["threats"])["status"]),
      health_services_status: text_or_nil(services["status"]),
      health_service_details: map_list_or_nil(services["serviceDetails"]),
      group_id: text_or_nil(group["id"]),
      group_name: text_or_nil(group["name"]),
      associated_person_id: text_or_nil(person["id"]),
      associated_person_name: text_or_nil(person["name"]),
      associated_person_via_login: text_or_nil(person["viaLogin"]),
      encryption_overall_status: text_or_nil(encryption["overallStatus"]),
      encryption_volumes: map_list_or_nil(encryption["volumes"]),
      lockdown_status: text_or_nil(map_or_empty(endpoint["lockdown"])["status"]),
      cloud_provider: text_or_nil(cloud["provider"]),
      cloud_instance_id: text_or_nil(cloud["instanceId"]),
      isolation_status: text_or_nil(isolation["status"]),
      isolation_admin_isolated: boolean_or_nil(isolation["adminIsolated"]),
      isolation_self_isolated: boolean_or_nil(isolation["selfIsolated"]),
      synced_at: synced_at
    }

    attrs =
      Enum.reduce(@os_fields, attrs, fn {column, property, cast}, attrs ->
        Map.put(attrs, column, cast(cast, os[property]))
      end)

    attrs
    |> take(endpoint, @text_fields, &text_or_nil/1)
    |> take(endpoint, @boolean_fields, &boolean_or_nil/1)
    |> take(endpoint, @string_list_fields, &string_list_or_nil/1)
    |> take(endpoint, @map_list_fields, &map_list_or_nil/1)
    |> take(endpoint, @map_fields, &map_or_nil/1)
    |> take(endpoint, @datetime_fields, &parse_datetime/1)
  end

  defp take(attrs, source, fields, cast) do
    Enum.reduce(fields, attrs, fn {column, property}, attrs ->
      Map.put(attrs, column, cast.(source[property]))
    end)
  end

  defp cast(:text, value), do: text_or_nil(value)
  defp cast(:boolean, value), do: boolean_or_nil(value)
  defp cast(:integer, value), do: integer_or_nil(value)

  defp text_or_nil(value) when value in [nil, ""], do: nil
  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_value), do: nil

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

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp raise_sync_error(provider, step, error) do
    raise Sophos.SyncError, provider_id: provider.id, step: step, error: error
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Safe, Sophos}

    def get_provider(account_id, id) do
      from(p in Sophos.PostureProvider,
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
      |> Safe.insert_all(Sophos.Device, rows,
        conflict_target: [:account_id, :sophos_id],
        on_conflict: {:replace, replace_fields}
      )
    end

    def delete_stale_devices(provider, cutoff) do
      from(d in Sophos.Device,
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
