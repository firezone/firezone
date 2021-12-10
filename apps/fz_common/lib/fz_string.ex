defmodule FzCommon.FzString do
  @moduledoc """
  Utility functions for working with Strings.
  """

  def to_boolean(str) when is_binary(str) do
    as_bool(String.downcase(str))
  end

  defp as_bool("true") do
    true
  end

  defp as_bool("false") do
    false
  end

  defp as_bool(unknown) do
    raise "Unknown boolean: string #{unknown} not one of ['true', 'false']."
  end
end
