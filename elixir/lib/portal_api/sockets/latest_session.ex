defmodule PortalAPI.Sockets.LatestSession do
  @moduledoc """
  Batch-upserts queued connect sessions onto the devices table.

  Each queue entry carries the session attrs plus connect-time metadata. The
  newest entry per device wins within a batch, and the update is guarded on
  `last_seen_at` so a flush from another node can never roll a device back to
  an older session. Entries whose token or device row no longer exists are
  returned as failed, separately per cause, so the caller can disconnect a
  deleted token's session without touching the device's other sessions.
  """
  alias __MODULE__.Database
  require Logger

  @spec upsert_all([{map(), map()}], :client_token_id | :gateway_token_id) ::
          {non_neg_integer(), [{map(), map()}], [{map(), map()}]}
  def upsert_all([], _token_field), do: {0, [], []}

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

    device_failed =
      Enum.filter(live, fn {attrs, _metadata} -> MapSet.member?(missing, attrs.device_id) end)

    {length(entries) - length(revoked) - length(device_failed), revoked, device_failed}
  rescue
    error ->
      Logger.error("Failed to upsert latest sessions onto devices: " <> Exception.message(error))

      # Returned as token-style failures so each entry's own session is
      # disconnected to retry, without booting the device's other sessions.
      {0, entries, []}
  end

  # Newest entry per device wins within a batch; rows are sorted so
  # concurrent flushes lock device rows in a consistent order.
  defp rows(entries, token_field) do
    entries
    |> Enum.group_by(fn {attrs, _metadata} -> {attrs.account_id, attrs.device_id} end)
    |> Enum.map(fn {_key, device_entries} ->
      {attrs, metadata} = Enum.max_by(device_entries, &connected_at/1, DateTime)
      attested = latest_attested_attrs(device_entries)

      %{
        account_id: attrs.account_id,
        device_id: attrs.device_id,
        actor_id: attrs[:actor_id],
        firezone_id: attrs[:firezone_id],
        device_serial: attrs[:device_serial],
        device_uuid: attrs[:device_uuid],
        identifier_for_vendor: attrs[:identifier_for_vendor],
        firebase_installation_id: attrs[:firebase_installation_id],
        last_attested_device_serial: attested[:last_attested_device_serial],
        last_attested_device_uuid: attested[:last_attested_device_uuid],
        last_attested_mdm_device_id: attested[:last_attested_mdm_device_id],
        last_attested_cert_serial: attested[:last_attested_cert_serial],
        last_attested_cert_fingerprint: attested[:last_attested_cert_fingerprint],
        last_attested_at: attested[:last_attested_at],
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

  # The newest entry wins the session fields above, but the attested snapshot
  # folds independently: an attested connect followed by an unattested
  # reconnect in the same batch must not drop the proof, because the
  # in-database coalesce can only preserve values that already flushed. The
  # snapshot with the most recent proof time wins, as a unit.
  defp latest_attested_attrs(device_entries) do
    device_entries
    |> Enum.map(fn {attrs, _metadata} -> attrs end)
    |> Enum.filter(& &1[:last_attested_at])
    |> case do
      [] -> %{}
      attested -> Enum.max_by(attested, & &1.last_attested_at, DateTime)
    end
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
    require Logger

    @value_types %{
      account_id: Ecto.UUID,
      device_id: Ecto.UUID,
      actor_id: Ecto.UUID,
      firezone_id: :string,
      device_serial: :string,
      device_uuid: :string,
      identifier_for_vendor: :string,
      firebase_installation_id: :string,
      last_attested_device_serial: :string,
      last_attested_device_uuid: :string,
      last_attested_mdm_device_id: :string,
      last_attested_cert_serial: :string,
      last_attested_cert_fingerprint: :string,
      last_attested_at: :utc_datetime_usec,
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
    @identity_probe_types %{
      account_id: Ecto.UUID,
      actor_id: Ecto.UUID,
      device_id: Ecto.UUID,
      firezone_id: :string
    }

    @attested_identifier_fields ~w[last_attested_device_serial last_attested_device_uuid last_attested_mdm_device_id]a

    # Only the MDM device id has a unique index, so it is the only identifier a
    # flush can collide on. A serial or UUID shared across rows is now normal:
    # a device whose MDM record changed enrolls as a new row and keeps the
    # hardware it reports.
    @attested_unique_fields ~w[last_attested_mdm_device_id]a
    @attested_fields @attested_identifier_fields ++
                       ~w[last_attested_cert_serial last_attested_cert_fingerprint last_attested_at]a
    @attested_probe_types %{
      account_id: Ecto.UUID,
      actor_id: Ecto.UUID,
      device_id: Ecto.UUID,
      last_attested_mdm_device_id: :string
    }

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
      existing = existing_token_ids(schema, probe_rows)

      probe_rows
      |> Enum.map(& &1.token_id)
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> MapSet.new()
    end

    defp existing_token_ids(schema, probe_rows) do
      from(t in schema,
        join: v in values(probe_rows, @token_probe_types),
        on: t.account_id == v.account_id and t.id == v.token_id,
        select: t.id
      )
      |> probe()
    end

    defp probe(queryable) do
      queryable |> Safe.unscoped() |> Safe.all() |> MapSet.new()
    end

    def update_devices([], _token_field), do: MapSet.new()

    def update_devices(rows, token_field) do
      do_update_devices(rows, token_field, _retries_left = 1)
    end

    # The probe-then-update window is not atomic: a flush on another node can
    # win a proposed firezone_id in between, so the bulk UPDATE can still hit
    # the unique index. Re-probing (which then sees the winner and strips the
    # loser) and retrying once resolves the collision at the entry level
    # instead of failing every session in the batch; anything beyond that is
    # left to the caller's batch-level rescue.
    defp do_update_devices(rows, token_field, retries_left) do
      rows =
        rows
        |> dedupe_proposed_firezone_ids()
        |> strip_conflicting_firezone_ids()
        |> dedupe_proposed_attested_identities()
        |> strip_conflicting_attested_identities()

      set =
        [
          # A device that proved an MDM device id is identified by its
          # certificate alone, so its firezone_id column is cleared: nothing
          # can then resolve the row from a client-supplied value. Otherwise
          # the latest session's firezone_id follows the device, and entries
          # that carry none (gateways) keep the row's current value.
          firezone_id:
            dynamic(
              [d, v],
              fragment(
                "CASE WHEN ? IS NOT NULL THEN NULL ELSE COALESCE(?, ?) END",
                v.last_attested_mdm_device_id,
                v.firezone_id,
                d.firezone_id
              )
            ),
          # Self-reported and refreshed on every connect. A client that omits
          # one keeps the row's current value; only the client can correct it.
          device_serial: dynamic([d, v], coalesce(v.device_serial, d.device_serial)),
          device_uuid: dynamic([d, v], coalesce(v.device_uuid, d.device_uuid)),
          identifier_for_vendor:
            dynamic([d, v], coalesce(v.identifier_for_vendor, d.identifier_for_vendor)),
          firebase_installation_id:
            dynamic([d, v], coalesce(v.firebase_installation_id, d.firebase_installation_id)),
          # The attested fields move as one snapshot, keyed by
          # last_attested_at (when the device last proved possession).
          # Entries that carry no snapshot keep the row's current values, and
          # a snapshot never replaces a fresher one: batches can flush out of
          # proof order across nodes. Whether the CURRENT session proved
          # possession is live connection state (the `attested?` presence
          # attribute), never row state. Clearing the fields is an explicit
          # admin action.
          last_attested_device_serial: attested_field(:last_attested_device_serial),
          last_attested_device_uuid: attested_field(:last_attested_device_uuid),
          last_attested_mdm_device_id: attested_field(:last_attested_mdm_device_id),
          last_attested_cert_serial: attested_field(:last_attested_cert_serial),
          last_attested_cert_fingerprint: attested_field(:last_attested_cert_fingerprint),
          last_attested_at: attested_field(:last_attested_at),
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
    rescue
      error in Postgrex.Error ->
        if retries_left > 0 and unique_violation?(error) do
          do_update_devices(rows, token_field, retries_left - 1)
        else
          reraise error, __STACKTRACE__
        end
    end

    defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
    defp unique_violation?(_error), do: false

    # The proposed snapshot is applied only when it is at least as fresh as
    # the row's (v's last_attested_at is NULL when the entry carries no
    # snapshot, so the CASE keeps the row's value, like the firezone_id
    # coalesce).
    defp attested_field(field) do
      dynamic(
        [d, v],
        fragment(
          "CASE WHEN ? IS NOT NULL AND (? IS NULL OR ? >= ?) THEN ? ELSE ? END",
          v.last_attested_at,
          d.last_attested_at,
          v.last_attested_at,
          d.last_attested_at,
          field(v, ^field),
          field(d, ^field)
        )
      )
    end

    # Two rows in the same batch can propose the same previously unused
    # {account_id, actor_id, firezone_id}: both would pass the persisted-row
    # probe and the bulk UPDATE would violate the unique index, failing every
    # session in the batch. The newest session wins the identifier (device_id
    # tie-break keeps it deterministic); losers keep their session but skip
    # the identity change, exactly like a persisted-row conflict.
    defp dedupe_proposed_firezone_ids(rows) do
      losers =
        rows
        |> Enum.filter(&(not is_nil(&1.firezone_id) and not is_nil(&1.actor_id)))
        |> Enum.group_by(&{&1.account_id, &1.actor_id, &1.firezone_id})
        |> Enum.flat_map(fn {_key, contenders} ->
          contenders |> sort_newest_first() |> tl()
        end)

      loser_ids = MapSet.new(losers, & &1.device_id)

      for loser <- losers do
        Logger.warning(
          "Skipping firezone_id merge during flush: another device in the same batch claims this firezone_id",
          device_id: loser.device_id,
          firezone_id: loser.firezone_id
        )
      end

      Enum.map(rows, fn row ->
        if MapSet.member?(loser_ids, row.device_id) do
          %{row | firezone_id: nil}
        else
          row
        end
      end)
    end

    defp sort_newest_first([single]), do: [single]

    defp sort_newest_first(contenders) do
      Enum.sort(contenders, fn a, b ->
        case DateTime.compare(a.last_seen_at, b.last_seen_at) do
          :gt -> true
          :lt -> false
          :eq -> a.device_id >= b.device_id
        end
      end)
    end

    # A merged firezone_id can collide with another device row of the same
    # actor. The colliding entry keeps its session but skips the identity
    # change, so one poisoned entry cannot fail the whole batch; the merge
    # retries on the device's next connect. Entries carry a firezone_id only
    # when their connect actually adopted a new one, so in the steady state
    # this probe has nothing to check and issues no query. The
    # probe-then-update window is not atomic: a collision that appears in
    # between still raises unique_violation, which the caller's rescue turns
    # into failed entries that reconnect and retry.
    #
    # Attested devices never contend here: they carry no firezone_id and the
    # column is cleared for them, so only unattested merges reach this probe.
    defp strip_conflicting_firezone_ids(rows) do
      probe_rows =
        for row <- rows, not is_nil(row.firezone_id), not is_nil(row.actor_id) do
          Map.take(row, [:account_id, :actor_id, :device_id, :firezone_id])
        end

      conflicts =
        if probe_rows == [] do
          MapSet.new()
        else
          from(d in Device,
            join: v in values(probe_rows, @identity_probe_types),
            on:
              d.account_id == v.account_id and d.actor_id == v.actor_id and
                d.firezone_id == v.firezone_id and d.id != v.device_id,
            where: d.type == :client,
            select: %{device_id: v.device_id, conflicting_id: d.id, firezone_id: v.firezone_id}
          )
          |> probe()
        end

      conflicted = MapSet.new(conflicts, & &1.device_id)

      for conflict <- conflicts do
        Logger.warning(
          "Skipping firezone_id merge during flush: another device row already holds this firezone_id",
          device_id: conflict.device_id,
          conflicting_device_id: conflict.conflicting_id,
          firezone_id: conflict.firezone_id
        )
      end

      Enum.map(rows, fn row ->
        if MapSet.member?(conflicted, row.device_id) do
          %{row | firezone_id: nil}
        else
          row
        end
      end)
    end

    # Two rows in the same batch can propose the same attested identifier for
    # different devices of one actor (a cloned certificate, or two machines
    # whose MDM stamped the same identity), which would violate the partial
    # unique indexes and fail every session in the batch. The snapshot with
    # the freshest proof wins; losers keep their session but skip the
    # attested update entirely, since the snapshot is all-or-nothing.
    defp dedupe_proposed_attested_identities(rows) do
      losers =
        for field <- @attested_unique_fields,
            {_key, contenders} <-
              rows
              |> Enum.filter(&(not is_nil(Map.fetch!(&1, field)) and not is_nil(&1.actor_id)))
              |> Enum.group_by(&{&1.account_id, &1.actor_id, Map.fetch!(&1, field)}),
            loser <- contenders |> sort_freshest_proof_first() |> tl(),
            uniq: true do
          %{device_id: loser.device_id, field: field}
        end

      loser_ids = MapSet.new(losers, & &1.device_id)

      for loser <- losers do
        Logger.warning(
          "Skipping attested identity during flush: another device in the same batch claims this identifier",
          device_id: loser.device_id,
          field: loser.field
        )
      end

      strip_attested_fields(rows, loser_ids)
    end

    defp sort_freshest_proof_first(contenders) do
      Enum.sort(contenders, fn a, b ->
        case DateTime.compare(a.last_attested_at, b.last_attested_at) do
          :gt -> true
          :lt -> false
          :eq -> a.device_id >= b.device_id
        end
      end)
    end

    # A proposed attested identifier can already sit on another device row of
    # the same actor: the connect-time adoption check refuses that, but a
    # concurrent adoption on another node can land in between. As with
    # firezone_id, the conflicting entry keeps its session and skips the
    # attested update; a conflict that appears between this probe and the
    # UPDATE still raises unique_violation, which the retry (which re-probes)
    # resolves at the entry level.
    defp strip_conflicting_attested_identities(rows) do
      probe_rows =
        for row <- rows,
            not is_nil(row.actor_id),
            Enum.any?(@attested_unique_fields, &(not is_nil(Map.fetch!(row, &1)))) do
          Map.take(row, [:account_id, :actor_id, :device_id | @attested_unique_fields])
        end

      conflicts =
        if probe_rows == [] do
          MapSet.new()
        else
          from(d in Device,
            join: v in values(probe_rows, @attested_probe_types),
            on: d.account_id == v.account_id and d.actor_id == v.actor_id and d.id != v.device_id,
            where:
              d.type == :client and
                d.last_attested_mdm_device_id == v.last_attested_mdm_device_id,
            select: %{device_id: v.device_id, conflicting_id: d.id}
          )
          |> probe()
        end

      for conflict <- conflicts do
        Logger.warning(
          "Skipping attested identity during flush: another device row already holds this identifier",
          device_id: conflict.device_id,
          conflicting_device_id: conflict.conflicting_id
        )
      end

      strip_attested_fields(rows, MapSet.new(conflicts, & &1.device_id))
    end

    defp strip_attested_fields(rows, device_ids) do
      nils = Map.new(@attested_fields, &{&1, nil})

      Enum.map(rows, fn row ->
        if MapSet.member?(device_ids, row.device_id) do
          Map.merge(row, nils)
        else
          row
        end
      end)
    end

    def existing_device_ids(rows) do
      rows
      |> Enum.map(&Map.take(&1, [:account_id, :device_id]))
      |> probe_device_ids()
    end

    defp probe_device_ids(probe_rows) do
      from(d in Device,
        join: v in values(probe_rows, @probe_types),
        on: d.account_id == v.account_id and d.id == v.device_id,
        select: d.id
      )
      |> probe()
    end
  end
end
