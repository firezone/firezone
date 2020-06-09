defmodule FgHttp.Util.FgMap do
  @moduledoc """
  Utilities for working with Maps
  """

  @doc """
  Removes key, value pairs from a Map if the value is nil
  """
  def compact(%{} = map) do
    for {k, v} <- map, v != nil, into: %{}, do: {k, v}
  end
end
