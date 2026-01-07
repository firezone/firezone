defmodule Portal.Relay do
  @moduledoc """
  Represents a connected relay. This is a pure struct (not persisted to DB).
  Relays are ephemeral and only exist while connected via presence.

  The `id` is a deterministic UUID derived from the stamp_secret at connection time.
  The `stamp_secret` is kept for TURN credential generation but never exposed in APIs.
  """

  defstruct [
    :id,
    :stamp_secret,
    :ipv4,
    :ipv6,
    :port,
    :lat,
    :lon
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          stamp_secret: String.t() | nil,
          ipv4: String.t() | nil,
          ipv6: String.t() | nil,
          port: integer(),
          lat: float() | nil,
          lon: float() | nil
        }

  @doc """
  Generates a deterministic UUID from the stamp_secret.
  This is used as the relay's public identifier without exposing the secret.
  """
  def generate_id(stamp_secret) when is_binary(stamp_secret) do
    # Extract 122 bits from the SHA256 hash (32 + 16 + 12 + 62), discarding 6 bits
    # that will be replaced with UUID version (4 bits) and variant (2 bits) metadata
    <<a::32, b::16, _::4, c::12, _::2, d::62, _rest::binary>> =
      :crypto.hash(:sha256, stamp_secret)

    # Construct 128-bit UUID: 122 bits from hash + version 4 (4 bits) + variant 10 (2 bits)
    <<a::32, b::16, 4::4, c::12, 2::2, d::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
