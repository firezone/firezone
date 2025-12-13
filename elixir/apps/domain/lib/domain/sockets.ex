defmodule Domain.Sockets do
  @moduledoc """
    Keeps our socket ID format in one place.
  """

  @typedoc ~s|A socket identifier in the format "socket:<uuid>"|
  @type socket_id :: String.t()

  @spec socket_id(Ecto.UUID.t()) :: socket_id()
  def socket_id(id) when is_binary(id), do: "socket:#{id}"
end
