defmodule FgCommon.FgMap do
  @moduledoc """
  Utilities for working with Maps
  """

  @doc """
  Removes key, value pairs from a Map if the value is nil
  """
  def compact(map) when is_map(map) do
    compact(map, nil)
  end

  def compact(map, match) do
    for {k, v} <- map, v != match, into: %{}, do: {k, v}
  end

  @doc """
  Stringifies atom keys.
  """
  def stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Enum.into(%{})
  end
end
