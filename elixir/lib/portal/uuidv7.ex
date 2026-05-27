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

  @max_unix_ms Bitwise.bsl(1, 48) - 1

  @spec generate(DateTime.t()) :: String.t()
  def generate(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_unix(:millisecond)
    |> build(datetime)
  end

  defp build(ms, datetime) when ms < 0 or ms > @max_unix_ms do
    raise ArgumentError,
          "timestamp #{inspect(datetime)} is outside the 48-bit unix_ts_ms range supported by UUIDv7"
  end

  defp build(ms, _datetime) do
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    raw = <<ms::48, 0b0111::4, rand_a::12, 0b10::2, rand_b::62>>
    {:ok, uuid} = Ecto.UUID.load(raw)
    uuid
  end
end
