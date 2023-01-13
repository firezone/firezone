defmodule FzHttpWeb.DocHelpers do
  def group(name, children) do
    {:group, {name, children}}
  end

  def attr(name, type, opts) do
    required? = Keyword.get(opts, :required?, false)
    description = Keyword.get(opts, :description)
    {:attr, {name, type, required?, description}}
  end

  def type(type), do: {:type, type}
  def type(type, example), do: {:type, {type, example}}

  def enum_type(type, values, example \\ nil),
    do: {:type, {:enum, type, values, example || List.first(values)}}
end
