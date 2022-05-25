defmodule FzCommon.FzInteger do
  @moduledoc """
  Utility functions for working with Integers.
  """

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

  def to_human_bytes(nil), do: to_human_bytes(0)

  def to_human_bytes(bytes) when is_integer(bytes) do
    FileSize.from_bytes(bytes, scale: :iec)
    |> FileSize.format(@byte_size_opts)
  end
end
