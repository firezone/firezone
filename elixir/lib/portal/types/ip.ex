defmodule Portal.Types.IP do
  @moduledoc """
  Ecto type implementation for IP's based on `Postgrex.INET` type,
  it always ignores netmask by setting it to `nil`.

  IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`) are normalized to IPv4 on
  cast, dump and load.
  """
  @behaviour Ecto.Type

  @type t :: %Postgrex.INET{
          address: tuple(),
          netmask: nil | integer()
        }

  def type, do: :inet

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(tuple) when tuple_size(tuple) == 4, do: {:ok, normalize(%Postgrex.INET{address: tuple})}
  def cast(tuple) when tuple_size(tuple) == 8, do: {:ok, normalize(%Postgrex.INET{address: tuple})}
  def cast(%Postgrex.INET{} = inet), do: {:ok, normalize(inet)}

  def cast(binary) when is_binary(binary) do
    with {:ok, address} <- Portal.Types.IPPort.cast_address(binary) do
      {:ok, normalize(%Postgrex.INET{address: address, netmask: nil})}
    else
      {:error, reason} ->
        {:error, message: "#{binary} is invalid: #{reason}"}
    end
  end

  def cast(_), do: :error

  def dump(%Postgrex.INET{} = inet), do: {:ok, normalize(inet)}
  def dump(tuple) when tuple_size(tuple) == 4, do: {:ok, normalize(%Postgrex.INET{address: tuple})}
  def dump(tuple) when tuple_size(tuple) == 8, do: {:ok, normalize(%Postgrex.INET{address: tuple})}
  def dump(_), do: :error

  def load(%Postgrex.INET{} = inet), do: {:ok, normalize(inet)}
  def load(_), do: :error

  def type(address) when tuple_size(address) == 4, do: :ipv4
  def type(address) when tuple_size(address) == 8, do: :ipv6

  def to_string(ip) when is_binary(ip), do: ip
  def to_string(%Postgrex.INET{} = inet), do: Portal.Types.INET.to_string(inet)

  # A dual-stack listener reports IPv4 peers as ::ffff:a.b.c.d.
  def unmap({0, 0, 0, 0, 0, 0xFFFF, w, x}) do
    {Bitwise.bsr(w, 8), Bitwise.band(w, 0xFF), Bitwise.bsr(x, 8), Bitwise.band(x, 0xFF)}
  end

  def unmap(address), do: address

  defp normalize(%Postgrex.INET{address: {0, 0, 0, 0, 0, 0xFFFF, _, _} = address, netmask: netmask} = inet)
       when netmask in [nil, 128] do
    %{inet | address: unmap(address), netmask: nil}
  end

  defp normalize(%Postgrex.INET{} = inet), do: inet
end
