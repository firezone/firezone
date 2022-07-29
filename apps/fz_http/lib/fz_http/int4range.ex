defmodule FzHttp.Int4Range do
  @moduledoc """
  Ecto type for Postgres' Int4Range type
  """
  use Ecto.Type
  def type, do: :int4range

  def cast(str) when is_binary(str) do
    res =
      String.trim(str)
      |> String.split("-", trim: true, parts: 2)
      |> Enum.map(&Integer.parse/1)

    case res do
      [{lower, _}, {upper, _}] -> cast([lower, upper])
      [{num, _}] -> {:ok, [num, num]}
      _ -> {:error, message: "Range Error: Bad format"}
    end
  end

  def cast([lower, nil]) do
    [lower, nil]
  end

  def cast([nil, upper]) do
    [nil, upper]
  end

  def cast([lower, upper]) do
    if upper >= lower do
      {:ok, [lower, upper]}
    else
      {:error, message: "Range Error: Lower bound higher than upper bound"}
    end
  end

  def cast(_), do: :error

  def load(%Postgrex.Range{
        lower: lower,
        upper: upper,
        lower_inclusive: lower_inclusive,
        upper_inclusive: upper_inclusive
      }) do
    upper = if upper != :unbound, do: upper - to_num(!upper_inclusive), else: nil
    lower = if lower != :unbound, do: lower + to_num(!lower_inclusive), else: nil
    {:ok, [lower, upper]}
  end

  def dump([lower, upper]) do
    {:ok,
     %Postgrex.Range{lower: lower, upper: upper, upper_inclusive: true, lower_inclusive: true}}
  end

  def dump(_), do: :error

  defp to_num(b), do: if(b, do: 1, else: 0)
end
