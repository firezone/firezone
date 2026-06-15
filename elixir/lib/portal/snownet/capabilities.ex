defmodule Portal.Snownet.Capabilities do
  @moduledoc """
  Capabilities of a snownet implementation, reported by clients and gateways
  in the `set_snownet_capabilities` channel message.

  The portal intersects (boolean AND) capabilities across both sides of each
  connection and re-emits the negotiated set with each `authorize_flow`,
  `flow_created`, and `client_device_access_authorized` message so the local
  snownet implementation knows what the remote supports.

  Unknown fields are dropped on intersect; missing fields default to `false`.
  Non-boolean values (e.g. a peer sending `%{"iceless" => "yes"}`) are
  treated as `false` rather than crashing the channel — the inputs come
  from untrusted clients and the `and` operator only accepts booleans.
  """

  @known_fields ~w(iceless)

  @doc """
  Returns the intersection of two capability maps as a fresh map containing
  every known field. Missing keys and non-boolean values are treated as
  `false`.
  """
  @spec intersect(map(), map()) :: map()
  def intersect(a, b) when is_map(a) and is_map(b) do
    for field <- @known_fields, into: %{} do
      {field, get_bool(a, field) and get_bool(b, field)}
    end
  end

  @doc """
  Normalize an untrusted payload to the canonical capability schema:
  every known field present as a boolean, unknown fields dropped,
  non-boolean values coerced to `false`. Use this when storing a
  payload in `socket.assigns` or presence metadata so untrusted clients
  cannot bloat them with arbitrary keys.
  """
  @spec normalize(map()) :: map()
  def normalize(payload) when is_map(payload) do
    for field <- @known_fields, into: %{} do
      {field, get_bool(payload, field)}
    end
  end

  defp get_bool(map, field) do
    case Map.get(map, field) do
      true -> true
      _ -> false
    end
  end
end
