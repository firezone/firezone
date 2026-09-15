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
  @type match :: {atom(), struct(), rung(), :intune | nil}

  @doc "Every provider row matched to the device, one entry per row."
  @spec match(Device.t()) :: [match()]
  def match(%Device{type: :client, account_id: account_id} = device) do
    keys = match_keys(device)
    types = Database.list_provider_types(account_id)

    if keys == [] or types == [] do
      []
    else
      matched = Enum.flat_map(types, &match_type(&1, keys, account_id))
      matched ++ link_defender(types, matched, account_id)
    end
  end

  def match(_device), do: []

  @doc "The matched rows grouped by provider type, the shape the posture evaluator reads."
  @spec rows_by_type(Device.t()) :: %{atom() => [struct()]}
  def rows_by_type(device) do
    device
    |> match()
    |> Enum.group_by(fn {type, _row, _rung, _via} -> type end, fn {_type, row, _rung, _via} -> row end)
  end

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

  defp match_type(type, keys, account_id) do
    case rung_conditions(type, keys) do
      [] ->
        []

      conditions ->
        schema(type)
        |> Database.list_rows(account_id, Enum.reduce(conditions, &dynamic(^&1 or ^&2)))
        |> Enum.map(&{type, &1, matched_rung(type, keys, &1), nil})
    end
  end

  defp link_defender(types, matched, account_id) do
    if :defender in types do
      matched
      |> Enum.flat_map(fn
        {:intune, %{entra_device_id: entra_id}, rung, _via} when is_binary(entra_id) -> [{entra_id, rung}]
        _other -> []
      end)
      |> Enum.sort_by(fn {_entra_id, rung} -> rung_rank(rung) end)
      |> Enum.uniq_by(fn {entra_id, _rung} -> entra_id end)
      |> match_defender_by_entra_id(account_id)
    else
      []
    end
  end

  defp match_defender_by_entra_id([], _account_id), do: []

  defp match_defender_by_entra_id(entra_ids, account_id) do
    rung_by_entra_id = Map.new(entra_ids)

    Defender.Device
    |> Database.list_rows(account_id, dynamic([d], d.entra_device_id in ^Map.keys(rung_by_entra_id)))
    |> Enum.map(&{:defender, &1, Map.fetch!(rung_by_entra_id, &1.entra_device_id), :intune})
  end

  defp rung_conditions(type, keys) do
    for {rung, value} <- keys,
        field_name <- rung_fields(type, rung),
        do: dynamic([d], field(d, ^field_name) == ^value)
  end

  defp matched_rung(type, keys, row) do
    Enum.find_value(keys, fn {rung, value} ->
      if Enum.any?(rung_fields(type, rung), &(Map.fetch!(row, &1) == value)), do: rung
    end)
  end
  defmodule Database do
    import Ecto.Query
    alias Portal.{PostureProvider, Safe}

    # Reads run unscoped: a policy check must see the rows whatever the
    # connecting actor may read, and the account filter keeps them in bounds.
    def list_provider_types(account_id) do
      from(p in PostureProvider, where: p.account_id == ^account_id, distinct: true, select: p.type)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def list_rows(schema, account_id, condition) do
      from(d in schema, where: d.account_id == ^account_id, where: ^condition)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
