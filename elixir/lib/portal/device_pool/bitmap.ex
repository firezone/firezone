defmodule Portal.DevicePool.Bitmap do
  @moduledoc """
  The members of a device pool as roaring bitmaps over the tunnel address ranges.

  Both `100.64.0.0/11` and `fd00:2021:1111::/107` leave 21 host bits, so a device is a
  small integer in each family: its offset from the range base. A pool's members are
  two bitmaps of such offsets, serialized in the portable roaring format so connlib
  reads them with the `roaring` crate. Only array and bitmap containers are written;
  addresses are handed out at random, so runs never form.
  """
  import Bitwise

  @serial_cookie_no_runs 12_346
  @array_container_max 4096
  @ipv4_base 100 <<< 24 ||| 64 <<< 16

  @typedoc "The wire form: both bitmaps base64 encoded."
  @type t :: %{ipv4: binary(), ipv6: binary()}

  @typedoc "The offsets of a pool's members in each family."
  @type sets :: %{ipv4: MapSet.t(non_neg_integer()), ipv6: MapSet.t(non_neg_integer())}

  @doc "The bitmaps of the given client devices, as base64 for the wire."
  @spec encode_devices([%{ipv4: Postgrex.INET.t(), ipv6: Postgrex.INET.t()}]) :: t()
  def encode_devices(devices), do: devices |> sets() |> wire()

  @doc "The offsets of the given client devices."
  @spec sets([%{ipv4: Postgrex.INET.t(), ipv6: Postgrex.INET.t()}]) :: sets()
  def sets(devices) do
    %{
      ipv4: MapSet.new(devices, &ipv4_offset(&1.ipv4)),
      ipv6: MapSet.new(devices, &ipv6_offset(&1.ipv6))
    }
  end

  @doc "The wire form of the offsets."
  @spec wire(sets()) :: t()
  def wire(%{ipv4: ipv4, ipv6: ipv6}) do
    %{
      ipv4: ipv4 |> Enum.to_list() |> encode() |> Base.encode64(),
      ipv6: ipv6 |> Enum.to_list() |> encode() |> Base.encode64()
    }
  end

  @doc "The offsets in `new` that `old` lacks, and the ones `old` had that `new` lacks."
  @spec diff(sets(), sets()) :: {added :: sets(), removed :: sets()}
  def diff(old, new) do
    {
      %{ipv4: MapSet.difference(new.ipv4, old.ipv4), ipv6: MapSet.difference(new.ipv6, old.ipv6)},
      %{ipv4: MapSet.difference(old.ipv4, new.ipv4), ipv6: MapSet.difference(old.ipv6, new.ipv6)}
    }
  end

  @doc "The offset of a tunnel IPv4 address from `100.64.0.0`."
  @spec ipv4_offset(Postgrex.INET.t()) :: non_neg_integer()
  def ipv4_offset(%Postgrex.INET{address: {a, b, c, d}}) do
    (a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d) - @ipv4_base
  end

  @doc "The offset of a tunnel IPv6 address from `fd00:2021:1111::`, its low 21 bits."
  @spec ipv6_offset(Postgrex.INET.t()) :: non_neg_integer()
  def ipv6_offset(%Postgrex.INET{address: {_, _, _, _, _, _, g7, g8}}) do
    (g7 &&& 0x1F) <<< 16 ||| g8
  end

  @doc "Serializes the offsets as a roaring bitmap in the portable format."
  @spec encode([non_neg_integer()]) :: binary()
  def encode(offsets) do
    containers =
      offsets
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.group_by(&(&1 >>> 16), &(&1 &&& 0xFFFF))
      |> Enum.sort()

    count = length(containers)

    descriptive_header =
      for {key, values} <- containers, into: <<>> do
        <<key::16-little, length(values) - 1::16-little>>
      end

    header = <<@serial_cookie_no_runs::32-little, count::32-little>> <> descriptive_header
    data_start = byte_size(header) + 4 * count

    {offset_header, data, _next} =
      Enum.reduce(containers, {<<>>, <<>>, data_start}, fn {_key, values},
                                                            {offsets, data, position} ->
        payload = container(values)

        {offsets <> <<position::32-little>>, data <> payload, position + byte_size(payload)}
      end)

    header <> offset_header <> data
  end

  defp container(values) when length(values) <= @array_container_max do
    for value <- values, into: <<>>, do: <<value::16-little>>
  end

  defp container(values) do
    words =
      Enum.reduce(values, %{}, fn value, words ->
        Map.update(words, value >>> 6, 1 <<< (value &&& 63), &(&1 ||| 1 <<< (value &&& 63)))
      end)

    for word <- 0..1023, into: <<>>, do: <<Map.get(words, word, 0)::64-little>>
  end
end
