defmodule PortalAPI.JSON do
  @moduledoc """
  Encodes structs into the maps the REST API sends, through
  `PortalAPI.JSON.Encoder`. A list is encoded element by element.
  """

  @spec encode(struct() | [struct()], keyword()) :: map() | [map()]
  def encode(structs, opts \\ [])
  def encode(structs, opts) when is_list(structs), do: Enum.map(structs, &encode(&1, opts))
  def encode(struct, opts), do: PortalAPI.JSON.Encoder.encode(struct, opts)
end
