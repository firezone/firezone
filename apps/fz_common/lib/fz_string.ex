defmodule FzCommon.FzString do
  @moduledoc """
  Utility functions for working with Strings.
  """

  def sanitize_filename(str) when is_binary(str) do
    str
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
  end

  def to_cidr_list("nil"), do: nil
  def to_cidr_list("null"), do: nil

  # xxx: to_ip?
  def to_cidr_list(str) do
    Jason.decode!(str)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn ip -> FzCommon.FzNet.valid_cidr?(ip) || FzCommon.FzNet.valid_ip?(ip) end)
    |> Enum.map(&FzCommon.FzNet.standardized_inet/1)
  end

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
