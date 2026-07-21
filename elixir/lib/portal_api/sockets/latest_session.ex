defmodule PortalAPI.Sockets.LatestSession do
  @moduledoc """
  Batch-upserts queued connect sessions onto the devices table.

  Each queue entry carries the session attrs plus connect-time metadata. The
  newest entry per device wins within a batch, and the update is guarded on
  `last_seen_at` so a flush from another node can never roll a device back to
  an older session. Entries whose device or token row no longer exists are
  returned as failed so the caller can disconnect them.
  """
  alias __MODULE__.Database
  require Logger

  @spec upsert_all([{map(), map()}], :client_token_id | :gateway_token_id) ::
          {non_neg_integer(), [{map(), map()}]}
  def upsert_all([], _token_field), do: {0, []}

  def upsert_all(entries, token_field)
      when token_field in [:client_token_id, :gateway_token_id] do
    # A token hard-deleted before its channel joined the token PG group missed
    # the deletion broadcast; failing the entry here is the backstop that
    # disconnects it. Channels enqueue only after joining the group, so a
    # deletion after this probe is always broadcast to the channel.
    dead_tokens = Database.missing_token_ids(entries, token_field)

    {live, revoked} =
      Enum.split_with(entries, fn {attrs, _metadata} ->
        not MapSet.member?(dead_tokens, Map.fetch!(attrs, token_field))
      end)

    rows = rows(live, token_field)
    updated_ids = Database.update_devices(rows, token_field)
    missing = missing_device_ids(rows, updated_ids)

    failed =
      revoked ++
        Enum.filter(live, fn {attrs, _metadata} -> MapSet.member?(missing, attrs.device_id) end)

    {length(entries) - length(failed), failed}
  rescue
    error ->
      Logger.error("Failed to upsert latest sessions onto devices: " <> Exception.message(error))

      {0, entries}
  end

  # Newest entry per device wins within a batch; rows are sorted so
  # concurrent flushes lock device rows in a consistent order.
  defp rows(entries, token_field) do
    entries
    |> Enum.group_by(fn {attrs, _metadata} -> {attrs.account_id, attrs.device_id} end)
    |> Enum.map(fn {_key, device_entries} ->
      {attrs, metadata} = Enum.max_by(device_entries, &connected_at/1, DateTime)

      %{
        account_id: attrs.account_id,
        device_id: attrs.device_id,
        token_id: Map.fetch!(attrs, token_field),
        public_key: attrs[:public_key],
        user_agent: attrs[:user_agent],
        remote_ip: attrs[:remote_ip],
        remote_ip_location_region: attrs[:remote_ip_location_region],
        remote_ip_location_city: attrs[:remote_ip_location_city],
        remote_ip_location_lat: attrs[:remote_ip_location_lat],
        remote_ip_location_lon: attrs[:remote_ip_location_lon],
        version: attrs[:version],
        last_seen_at: connected_at({attrs, metadata})
      }
    end)
    |> Enum.sort_by(&{&1.account_id, &1.device_id})
  end

  # Connect time from the queue entry's metadata; entries that carry none
  # fall back to the flush-time inserted_at the queue stamps on the attrs.
  defp connected_at({attrs, metadata}) do
    metadata[:timestamp] || attrs.inserted_at
  end

  # Rows can miss the update either because the device is gone (failed) or
  # because a newer flush already wrote past them (still durable); only the
  # former must be reported.
  defp missing_device_ids(rows, updated_ids) do
    leftovers = Enum.reject(rows, &MapSet.member?(updated_ids, &1.device_id))

    if leftovers == [] do
      MapSet.new()
    else
      existing = Database.existing_device_ids(leftovers)

      leftovers
      |> Enum.map(& &1.device_id)
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> MapSet.new()
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Device
    alias Portal.Safe

    @value_types %{
      account_id: Ecto.UUID,
      device_id: Ecto.UUID,
      token_id: Ecto.UUID,
      public_key: :string,
      user_agent: :string,
      remote_ip: Portal.Types.IP,
      remote_ip_location_region: :string,
      remote_ip_location_city: :string,
      remote_ip_location_lat: :float,
      remote_ip_location_lon: :float,
      version: :string,
      last_seen_at: :utc_datetime_usec
    }

    @probe_types %{account_id: Ecto.UUID, device_id: Ecto.UUID}
    @token_probe_types %{account_id: Ecto.UUID, token_id: Ecto.UUID}

    @token_schemas %{
      client_token_id: Portal.ClientToken,
      gateway_token_id: Portal.GatewayToken
    }

    def missing_token_ids(entries, token_field) do
      probe_rows =
        entries
        |> Enum.map(fn {attrs, _metadata} ->
          %{account_id: attrs.account_id, token_id: Map.fetch!(attrs, token_field)}
        end)
        |> Enum.uniq()

      schema = Map.fetch!(@token_schemas, token_field)

      existing =
        from(t in schema,
          join: v in values(probe_rows, @token_probe_types),
          on: t.account_id == v.account_id and t.id == v.token_id,
          select: t.id
        )
        |> Safe.unscoped()
        |> Safe.all()
        |> MapSet.new()

      probe_rows
      |> Enum.map(& &1.token_id)
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> MapSet.new()
    end

    def update_devices([], _token_field), do: MapSet.new()

    def update_devices(rows, token_field) do
      set =
        [
          public_key: dynamic([d, v], v.public_key),
          last_seen_user_agent: dynamic([d, v], v.user_agent),
          last_seen_remote_ip: dynamic([d, v], v.remote_ip),
          last_seen_remote_ip_location_region: dynamic([d, v], v.remote_ip_location_region),
          last_seen_remote_ip_location_city: dynamic([d, v], v.remote_ip_location_city),
          last_seen_remote_ip_location_lat: dynamic([d, v], v.remote_ip_location_lat),
          last_seen_remote_ip_location_lon: dynamic([d, v], v.remote_ip_location_lon),
          last_seen_version: dynamic([d, v], v.version),
          last_seen_at: dynamic([d, v], v.last_seen_at)
        ] ++ [{token_field, dynamic([d, v], v.token_id)}]

      {_count, ids} =
        from(d in Device,
          join: v in values(rows, @value_types),
          on: d.account_id == v.account_id and d.id == v.device_id,
          where: is_nil(d.last_seen_at) or v.last_seen_at >= d.last_seen_at,
          select: d.id,
          update: [set: ^set]
        )
        |> Safe.unscoped()
        |> Safe.update_all([])

      MapSet.new(ids)
    end

    def existing_device_ids(rows) do
      probe_rows = Enum.map(rows, &Map.take(&1, [:account_id, :device_id]))

      from(d in Device,
        join: v in values(probe_rows, @probe_types),
        on: d.account_id == v.account_id and d.id == v.device_id,
        select: d.id
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new()
    end
  end
end
