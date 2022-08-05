defmodule FzCommon.FzKernelVersion do
  @moduledoc """
  Helpers related to kernel version
  """

  @doc """
  Compares version tuple to current kernel version
  """
  def is_version_greater_than?(val) do
    case :os.version() do
      v when is_tuple(v) -> v > val
      _ -> false
    end
  end
end
