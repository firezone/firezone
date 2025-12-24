defmodule Domain.Types.IP do
  @moduledoc """
  Ecto type implementation for IP's based on `Postgrex.INET` type,
  it always ignores netmask by setting it to `nil`.
  """
  @behaviour Ecto.Type

  @type t :: %Postgrex.INET{
          address: tuple(),
          netmask: nil | integer()
        }

  def type, do: :inet

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(tuple) when tuple_size(tuple) == 4, do: {:ok, %Postgrex.INET{address: tuple}}
  def cast(tuple) when tuple_size(tuple) == 8, do: {:ok, %Postgrex.INET{address: tuple}}
  def cast(%Postgrex.INET{} = inet), do: {:ok, inet}

  def cast(binary) when is_binary(binary) do
    with {:ok, address} <- Domain.Types.IPPort.cast_address(binary) do
      {:ok, %Postgrex.INET{address: address, netmask: nil}}
    else
      {:error, reason} ->
        {:error, message: "#{binary} is invalid: #{reason}"}
    end
  end

  def cast(_), do: :error

  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(tuple) when tuple_size(tuple) == 4, do: {:ok, %Postgrex.INET{address: tuple}}
  def dump(tuple) when tuple_size(tuple) == 8, do: {:ok, %Postgrex.INET{address: tuple}}
  def dump(_), do: :error

  def load(%Postgrex.INET{} = inet), do: {:ok, inet}
  def load(_), do: :error

  def type(address) when tuple_size(address) == 4, do: :ipv4
  def type(address) when tuple_size(address) == 8, do: :ipv6

  def to_string(ip) when is_binary(ip), do: ip
  def to_string(%Postgrex.INET{} = inet), do: Domain.Types.INET.to_string(inet)
end
