defmodule FzHttp.Int4Range do
  @moduledoc """
  Ecto type for Postgres' Int4Range type
  """
  # Note: we represent a port range as a string: lower - upper for ease of use
  # with Phoenix LiveView and nftables
  use Ecto.Type

  def type, do: :int4range

  def cast(str) when is_binary(str) do
    case parse_range(str) do
      {:ok, range} -> cast(range)
      err -> err
    end
  end

  def cast([num, num]) when is_number(num) do
    {:ok, Integer.to_string(num)}
  end

  def cast([lower, upper]) when upper >= lower, do: {:ok, "#{lower} - #{upper}"}
  def cast([_, _]), do: {:error, message: "Range Error: Lower bound higher than upper bound"}

  def load(%Postgrex.Range{
        lower: lower,
        upper: upper,
        lower_inclusive: lower_inclusive,
        upper_inclusive: upper_inclusive
      }) do
    upper = if upper != :unbound, do: upper - to_num(!upper_inclusive), else: nil
    lower = if lower != :unbound, do: lower + to_num(!lower_inclusive), else: nil
    cast([lower, upper])
  end

  def dump(range) when is_binary(range) do
    {:ok, range_list} = parse_range(range)
    dump(range_list)
  end

  def dump([lower, upper]) do
    {:ok,
     %Postgrex.Range{lower: lower, upper: upper, upper_inclusive: true, lower_inclusive: true}}
  end

  def dump(_), do: :error

  def parse_range(range) when is_binary(range) do
    res =
      String.trim(range)
      |> String.split("-", trim: true, parts: 2)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Integer.parse/1)

    case res do
      [{lower, _}, {upper, _}] -> {:ok, [lower, upper]}
      [{num, _}] -> {:ok, [num, num]}
      _ -> {:error, message: "Range Error: Bad format"}
    end
  end

  defp to_num(b) when b, do: 1
  defp to_num(_b), do: 0
end
