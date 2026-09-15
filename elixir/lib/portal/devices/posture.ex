defmodule Portal.Devices.Posture do
  @moduledoc """
  Finds the posture provider rows that describe a client device.

  A row is matched on the strongest identifier it shares with the device:

    1. the MDM device id the device's certificate attested,
    2. the hardware serial that certificate attested,
    3. the self-reported hardware serial.

  Only the first two prove anything. The third is only as trustworthy as the
  actor and the device running the Client, so callers label rows matched that
  way.

  Defender for Endpoint issues no device id of its own for a certificate to
  attest and its machines report no hardware serial, so a Defender row is
  reached through the Intune row already matched to this device: both carry
  the same Entra device id. A row reached that way is only as well matched as
  the Intune row that led to it.
  """

  import Ecto.Query

  alias Portal.{Defender, Device, Intune, Iru, Santa, SentinelOne}
  alias __MODULE__.Database

  @type rung :: :mdm_device_id | :attested_serial | :device_serial
  @type key :: {:mdm_device_id | :serial | :entra_device_id, String.t()}
  @type match :: {atom(), struct(), rung(), :intune | nil}

  @doc "Every provider row matched to the device, one entry per row."
  @spec match(Device.t()) :: [match()]
  def match(%Device{type: :client} = device), do: device |> match_all() |> Map.get(device.id, [])
  def match(_device), do: []

  @doc """
  The matched rows of many client devices of one account, keyed by device id.

  One statement joins the devices to every provider table on the identifiers
  of the ladder, and to Defender through the Intune row, so a batch of a
  thousand devices costs the same round trip as one.
  """
  @spec match_all([Device.t()] | Device.t()) :: %{Ecto.UUID.t() => [match()]}
  def match_all(%Device{} = device), do: match_all([device])

  def match_all(devices) when is_list(devices) do
    keys_by_id =
      for %Device{type: :client} = device <- devices, match_keys(device) != [], into: %{} do
        {device.id, match_keys(device)}
      end

    case Map.keys(keys_by_id) do
      [] ->
        %{}

      device_ids ->
        account_id = devices |> hd() |> Map.fetch!(:account_id)

        account_id
        |> Database.list_matches(device_ids)
        |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
        |> Map.new(fn {device_id, rows} -> {device_id, matches(rows, Map.fetch!(keys_by_id, device_id))} end)
    end
  end

  @doc "The matched rows grouped by provider type, the shape the posture evaluator reads."
  @spec rows_by_type(Device.t()) :: %{atom() => [struct()]}
  def rows_by_type(device), do: device |> match() |> group_rows()

  @doc "`rows_by_type/1` for a batch of devices of one account, keyed by device id."
  @spec rows_by_type_all([Device.t()]) :: %{Ecto.UUID.t() => %{atom() => [struct()]}}
  def rows_by_type_all(devices), do: devices |> match_all() |> Map.new(fn {id, rows} -> {id, group_rows(rows)} end)

  @spec rung_rank(rung()) :: 0 | 1 | 2
  def rung_rank(:mdm_device_id), do: 0
  def rung_rank(:attested_serial), do: 1
  def rung_rank(:device_serial), do: 2

  @doc "The mirror schema of a provider type."
  @spec schema(atom()) :: module()
  def schema(:intune), do: Intune.Device
  def schema(:iru), do: Iru.Device
  def schema(:defender), do: Defender.Device
  def schema(:santa), do: Santa.Device
  def schema(:sentinelone), do: SentinelOne.Device

  @types ~w[intune iru defender santa sentinelone]a

  @spec types() :: [atom()]
  def types, do: @types

  @doc "The mirror schemas, so a change can be recognised as a provider row."
  @spec schemas() :: [module()]
  def schemas, do: Enum.map(@types, &schema/1)

  @doc "The provider type of a mirror schema."
  @spec type(module()) :: atom()
  def type(Intune.Device), do: :intune
  def type(Iru.Device), do: :iru
  def type(Defender.Device), do: :defender
  def type(Santa.Device), do: :santa
  def type(SentinelOne.Device), do: :sentinelone

  @doc """
  The identifiers a provider row can be matched on, which are the keys its
  changes are published under. A Defender row is reached through an Intune
  row, so it is keyed by its Entra device id instead.
  """
  @spec row_keys(struct()) :: [key()]
  def row_keys(%Defender.Device{entra_device_id: entra_id}), do: keys(entra_device_id: entra_id)

  def row_keys(%schema{} = row) do
    type = type(schema)

    keys(
      for {kind, rung} <- [mdm_device_id: :mdm_device_id, serial: :device_serial],
          field <- rung_fields(type, rung),
          do: {kind, Map.fetch!(row, field)}
    )
  end

  @doc "The identifiers a client device is matched on, which are the keys its channel listens under."
  @spec device_keys(Device.t()) :: [key()]
  def device_keys(%Device{} = device) do
    keys(
      mdm_device_id: device.last_attested_mdm_device_id,
      serial: device.last_attested_device_serial,
      serial: device.device_serial
    )
  end

  @doc "The Entra device ids of the matched Intune rows, which are the keys Defender rows arrive under."
  @spec entra_keys(%{atom() => [struct()]}) :: [key()]
  def entra_keys(rows_by_type) do
    rows_by_type
    |> Map.get(:intune, [])
    |> Enum.map(&{:entra_device_id, &1.entra_device_id})
    |> keys()
  end

  # Which columns of a provider's row each rung is compared against. Both the
  # query and the credit given to a row it returns are built from this, so they
  # can never disagree. Only an MDM issues a device id a certificate attests, so
  # neither EDR answers that rung. Defender answers none: its machine entity
  # carries no hardware serial either, which is why it is reached through Intune.
  @spec rung_fields(atom(), rung()) :: [atom()]
  def rung_fields(:intune, :mdm_device_id), do: [:intune_id]
  def rung_fields(:intune, _serial_rung), do: [:serial_number]
  def rung_fields(:iru, :mdm_device_id), do: [:iru_id]
  def rung_fields(:iru, _serial_rung), do: [:serial_number]
  def rung_fields(:defender, _rung), do: []
  def rung_fields(:santa, :mdm_device_id), do: []
  def rung_fields(:santa, _serial_rung), do: [:serial_number]
  def rung_fields(:sentinelone, :mdm_device_id), do: []
  def rung_fields(:sentinelone, _serial_rung), do: [:serial_number]

  defp match_keys(%Device{} = device) do
    Enum.reject(
      [
        mdm_device_id: device.last_attested_mdm_device_id,
        attested_serial: device.last_attested_device_serial,
        device_serial: device.device_serial
      ],
      fn {_rung, value} -> is_nil(value) end
    )
  end

  # One joined result row per combination of matched provider rows; the
  # struct of a provider that matched nothing is nil. Defender rides on the
  # Intune row it was joined through and inherits that row's rung.
  defp matches(rows, keys) do
    provider_matches =
      for {type, index} <- [intune: 0, iru: 1, santa: 2, sentinelone: 3],
          row <- rows |> Enum.map(&elem(&1, index)) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(&Ecto.primary_key/1),
          rung = matched_rung(type, keys, row),
          not is_nil(rung),
          do: {type, row, rung, nil}

    defender_matches =
      for {intune, _iru, _santa, _sentinelone, defender} <- rows,
          not is_nil(intune) and not is_nil(defender),
          rung = matched_rung(:intune, keys, intune),
          not is_nil(rung),
          do: {:defender, defender, rung, :intune}

    defender_matches =
      defender_matches
      |> Enum.sort_by(fn {_type, _row, rung, _via} -> rung_rank(rung) end)
      |> Enum.uniq_by(fn {_type, row, _rung, _via} -> Ecto.primary_key(row) end)

    provider_matches ++ defender_matches
  end

  defp matched_rung(type, keys, row) do
    Enum.find_value(keys, fn {rung, value} ->
      if Enum.any?(rung_fields(type, rung), &(Map.fetch!(row, &1) == value)), do: rung
    end)
  end

  defp keys(pairs) do
    pairs
    |> Enum.reject(fn {_kind, value} -> is_nil(value) end)
    |> Enum.uniq()
  end

  defp group_rows(matches) do
    Enum.group_by(matches, fn {type, _row, _rung, _via} -> type end, fn {_type, row, _rung, _via} -> row end)
  end
  defmodule Database do
    import Ecto.Query
    alias Portal.{Defender, Device, Intune, Iru, Safe, Santa, SentinelOne}

    # Runs unscoped: a policy check must see the rows whatever the connecting
    # actor may read, and the account filter keeps them in bounds. The join
    # conditions are the matching ladder; `rung_fields/2` names the same
    # columns so the credit given to a returned row can never disagree.
    def list_matches(account_id, device_ids) do
      from(d in Device, as: :device, where: d.account_id == ^account_id and d.id in ^device_ids)
      |> join_intune()
      |> join_iru()
      |> join_santa()
      |> join_sentinelone()
      |> join_defender()
      |> select([device: d, intune: i, iru: r, santa: s, sentinelone: o, defender: f], {d.id, i, r, s, o, f})
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp join_intune(query) do
      join(query, :left, [device: d], i in Intune.Device,
        as: :intune,
        on:
          i.account_id == d.account_id and
            (i.intune_id == d.last_attested_mdm_device_id or
               i.serial_number == d.last_attested_device_serial or
               i.serial_number == d.device_serial)
      )
    end

    defp join_iru(query) do
      join(query, :left, [device: d], r in Iru.Device,
        as: :iru,
        on:
          r.account_id == d.account_id and
            (r.iru_id == d.last_attested_mdm_device_id or
               r.serial_number == d.last_attested_device_serial or
               r.serial_number == d.device_serial)
      )
    end

    defp join_santa(query) do
      join(query, :left, [device: d], s in Santa.Device,
        as: :santa,
        on:
          s.account_id == d.account_id and
            (s.serial_number == d.last_attested_device_serial or s.serial_number == d.device_serial)
      )
    end

    defp join_sentinelone(query) do
      join(query, :left, [device: d], o in SentinelOne.Device,
        as: :sentinelone,
        on:
          o.account_id == d.account_id and
            (o.serial_number == d.last_attested_device_serial or o.serial_number == d.device_serial)
      )
    end

    defp join_defender(query) do
      join(query, :left, [device: d, intune: i], f in Defender.Device,
        as: :defender,
        on: f.account_id == d.account_id and f.entra_device_id == i.entra_device_id
      )
    end
  end
end
