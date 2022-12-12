defmodule FzCommon.FzInteger do
  @moduledoc """
  Utility functions for working with Integers.
  """

  import Bitwise

  # Postgres max int size is 4 bytes
  @max_integer 2_147_483_647

  @byte_size_opts [
    precision: 2,
    delimiter: ""
  ]

  def clamp(num, min, _max) when is_integer(num) and num < min, do: min
  def clamp(num, _min, max) when is_integer(num) and num > max, do: max
  def clamp(num, _min, _max) when is_integer(num), do: num

  def max_pg_integer do
    @max_integer
  end

  def from_inet(tuple) when tuple_size(tuple) == 4, do: from_inet4(tuple)
  def from_inet(tuple) when tuple_size(tuple) == 8, do: from_inet6(tuple)

  defp from_inet4({o3, o2, o1, o0}) do
    (o3 <<< 24) + (o2 <<< 16) + (o1 <<< 8) + o0
  end

  defp from_inet6({o7, o6, o5, o4, o3, o2, o1, o0}) do
    (o7 <<< 112) + (o6 <<< 96) + (o5 <<< 80) + (o4 <<< 64) +
      (o3 <<< 48) + (o2 <<< 32) + (o1 <<< 16) + o0
  end

  def to_inet4(integer) do
    o0 = integer &&& 0xFF
    o1 = (integer &&& 0xFF00) >>> 8
    o2 = (integer &&& 0xFF0000) >>> 16
    o3 = (integer &&& 0xFF000000) >>> 24

    {o3, o2, o1, o0}
  end

  def to_inet6(integer) do
    o0 = integer &&& 0xFFFF
    o1 = (integer &&& 0xFFFF0000) >>> 16
    o2 = (integer &&& 0xFFFF00000000) >>> 32
    o3 = (integer &&& 0xFFFF000000000000) >>> 48
    o4 = (integer &&& 0xFFFF0000000000000000) >>> 64
    o5 = (integer &&& 0xFFFF00000000000000000000) >>> 80
    o6 = (integer &&& 0xFFFF000000000000000000000000) >>> 96
    o7 = (integer &&& 0xFFFF0000000000000000000000000000) >>> 112

    {o7, o6, o5, o4, o3, o2, o1, o0}
  end

  def to_human_bytes(nil), do: to_human_bytes(0)

  def to_human_bytes(bytes) when is_integer(bytes) do
    FileSize.from_bytes(bytes, scale: :iec)
    |> FileSize.format(@byte_size_opts)
  end
end
