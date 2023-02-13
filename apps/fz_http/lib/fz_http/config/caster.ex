defmodule FzHttp.Config.Caster do
  @moduledoc """
  This module allows to cast values to a defined type.

  Notice that only the Ecto types that don't allow to use `c:Ecto.Type.cast/1`
  to cast a binary needs to be casted this way,
  """

  def cast(value, {:array, separator, type, _opts}) do
    cast(value, {:array, separator, type})
  end

  def cast(value, {:array, separator, type}) when is_binary(value) do
    value
    |> String.split(separator)
    |> Enum.map(&cast(&1, type))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, {:ok, _acc} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  def cast(json, :embed) when is_binary(json), do: Jason.decode(json)
  def cast(json, {:embed, _schema}) when is_binary(json), do: Jason.decode(json)
  def cast(json, :map) when is_binary(json), do: Jason.decode(json)
  def cast(json, {:map, _term}) when is_binary(json), do: Jason.decode(json)
  def cast(json, :json_array) when is_binary(json), do: Jason.decode(json)
  def cast(json, {:json_array, _term}) when is_binary(json), do: Jason.decode(json)

  def cast("true", :boolean), do: {:ok, true}
  def cast("false", :boolean), do: {:ok, false}
  def cast("", :boolean), do: {:ok, nil}

  def cast(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} ->
        {:ok, value}

      {value, remainder} ->
        {:error,
         "can not be cast to an integer, " <>
           "got a reminder #{remainder} after an integer value #{value}"}

      :error ->
        {:error, "can not be cast to an integer"}
    end
  end

  def cast(nil, :integer), do: {:ok, nil}

  def cast(value, _type), do: {:ok, value}
end
