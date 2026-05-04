defmodule Portal.Snownet.Capabilities do
  @moduledoc """
  Capabilities of a snownet implementation, reported by clients and gateways
  in the `set_snownet_capabilities` channel message.

  The portal intersects (boolean AND) capabilities across both sides of each
  connection and re-emits the negotiated set with each `authorize_flow`,
  `flow_created`, and `client_device_access_authorized` message so the local
  snownet implementation knows what the remote supports.

  Unknown fields are dropped on intersect; missing fields default to `false`.
  """

  @known_fields ~w(iceless)

  @doc """
  Returns the intersection of two capability maps as a fresh map containing
  every known field. Missing keys are treated as `false`.
  """
  @spec intersect(map(), map()) :: map()
  def intersect(a, b) when is_map(a) and is_map(b) do
    for field <- @known_fields, into: %{} do
      {field, Map.get(a, field, false) and Map.get(b, field, false)}
    end
  end
end
