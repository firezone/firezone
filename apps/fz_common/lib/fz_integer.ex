defmodule FzCommon.FzInteger do
  @moduledoc """
  Utility functions for working with Integers.
  """

  def clamp(num, min, _max) when is_integer(num) and num < min, do: min
  def clamp(num, _min, max) when is_integer(num) and num > max, do: max
  def clamp(num, _min, _max) when is_integer(num), do: num
end
