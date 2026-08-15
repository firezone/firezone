defmodule PortalAPI.Filters do
  @spec maybe_append(keyword(), atom(), term()) :: keyword()
  def maybe_append(filters, _name, nil), do: filters
  def maybe_append(filters, name, value), do: filters ++ [{name, value}]
end
