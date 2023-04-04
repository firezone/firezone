defmodule Domain.Types.Int4Range do
  @moduledoc """
  Ecto type for Postgres' Int4Range type.any()

  It's used tp represent a port range as a string: lower-upper for ease of use
  with Phoenix LiveView and nftables.
  """
  use Ecto.Type
  @format_error "bad format"
  @cast_error "lower value cannot be higher than upper value"

  def type, do: :int4range

  def cast(str) when is_binary(str) do
    # We need to handle this case since postgre notifies
    # before inserting the range in the database using this format
    parse_str =
      if String.starts_with?(str, ["[", "("]) do
        &parse_bracket/1
      else
        &parse_range/1
      end

    case parse_str.(str) do
      {:ok, range} -> cast(range)
      err -> err
    end
  end

  def cast([num, num]) when is_number(num) do
    {:ok, Integer.to_string(num)}
  end

  def cast([lower, upper]) when upper >= lower, do: {:ok, "#{lower} - #{upper}"}
  def cast([_, _]), do: {:error, message: @cast_error}

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

  defp parse_range(range) do
    res =
      String.trim(range)
      |> String.split("-", trim: true, parts: 2)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Integer.parse/1)

    case res do
      [{lower, _}, {upper, _}] -> {:ok, [lower, upper]}
      [{num, _}] -> {:ok, [num, num]}
      _ -> {:error, message: @format_error}
    end
  end

  defp parse_bracket(bracket) do
    res =
      Regex.named_captures(
        ~r/(?<start>[\[|(])\s*(?<lower>\d+),\s*(?<upper>\d+)\s*(?<end>[\]|\)])/,
        bracket
      )

    if is_nil(res) || Enum.any?(["lower", "upper", "start", "end"], &is_nil(res[&1])) do
      {:error, message: @format_error}
    else
      lower = String.to_integer(res["lower"]) + to_num(res["start"] == "(")
      upper = String.to_integer(res["upper"]) - to_num(res["end"] == ")")
      {:ok, [lower, upper]}
    end
  end

  defp to_num(b) when b, do: 1
  defp to_num(_b), do: 0
end
