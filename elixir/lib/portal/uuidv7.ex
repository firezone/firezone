defmodule Portal.UUIDv7 do
  @moduledoc """
  Generates UUIDv7 values per RFC 9562.

  Layout (128 bits):

      48 bits unix_ts_ms
       4 bits version (0b0111)
      12 bits rand_a
       2 bits variant (0b10)
      62 bits rand_b
  """

  @spec generate(DateTime.t()) :: String.t()
  def generate(%DateTime{} = datetime) do
    ms = DateTime.to_unix(datetime, :millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    raw = <<ms::48, 0b0111::4, rand_a::12, 0b10::2, rand_b::62>>
    {:ok, uuid} = Ecto.UUID.load(raw)
    uuid
  end
end
