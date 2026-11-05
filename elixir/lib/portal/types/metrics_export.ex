defmodule Portal.Types.MetricsExport do
  @moduledoc """
  Which metrics an account's Clients and Gateways export: `:off`, `:all`, or a
  non-empty list of metric names. Stored as `jsonb`: `"off"`, `"all"` or an array.
  """
  use Ecto.Type

  @type t :: :off | :all | [String.t(), ...]

  def type, do: :any

  def cast(value) when value in [:off, "off"], do: {:ok, :off}
  def cast(value) when value in [:all, "all"], do: {:ok, :all}

  def cast([_ | _] = names) do
    if Enum.all?(names, &is_binary/1), do: {:ok, names}, else: :error
  end

  def cast(_value), do: :error

  def load(value), do: cast(value)

  def dump(:off), do: {:ok, "off"}
  def dump(:all), do: {:ok, "all"}
  def dump([_ | _] = names), do: {:ok, names}
  def dump(_value), do: :error
end
