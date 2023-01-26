defmodule FzHttp.Config.Caster do
  @moduledoc """
  This module allows to cast values to a defined type.

  Notice that only the Ecto types that don't allow to use `c:Ecto.Type.cast/1`
  to cast a binary needs to be casted this way,
  """

  def cast(value, {:array, separator, type}) when is_binary(value),
    do: value |> String.split(separator) |> cast(type)

  def cast("true", :boolean), do: true
  def cast("false", :boolean), do: false
  def cast("", :boolean), do: nil

  def cast(value, :integer) when is_binary(value), do: String.to_integer(value)
  def cast(value, :integer) when is_number(value), do: value
  def cast(nil, :integer), do: nil

  def cast(value, _type), do: value
end
