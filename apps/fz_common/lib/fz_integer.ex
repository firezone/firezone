defmodule FzCommon.FzInteger do
  @moduledoc """
  Utility functions for working with Integers.
  """

  # Postgres max int size is 4 bytes
  @max_integer 2_147_483_647

  def clamp(num, min, _max) when is_integer(num) and num < min, do: min
  def clamp(num, _min, max) when is_integer(num) and num > max, do: max
  def clamp(num, _min, _max) when is_integer(num), do: num

  def max_pg_integer do
    @max_integer
  end
end
