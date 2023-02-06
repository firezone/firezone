defmodule FzHttp.Types.INET do
  @moduledoc """
  INET is an implementation for native PostgreSQL `inet` type which can hold either CIDR or an IP address.
  """
  @behaviour Ecto.Type

  def type, do: :inet

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(%Postgrex.INET{} = struct), do: {:ok, struct}
  def cast(tuple) when is_tuple(tuple), do: cast(%Postgrex.INET{address: tuple})

  def cast(binary) when is_binary(binary) do
    with {:ok, {binary_address, binary_netmask}} <- parse_binary(binary),
         {:ok, address} <- cast_address(binary_address),
         {:ok, netmask} <- cast_netmask(binary_netmask) do
      {:ok, %Postgrex.INET{address: address, netmask: netmask}}
    else
      _error -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  defp parse_binary(binary) do
    binary = String.trim(binary)

    case String.split(binary, "/", parts: 2) do
      [binary_address, binary_netmask] -> {:ok, {binary_address, binary_netmask}}
      [binary_address] -> {:ok, {binary_address, nil}}
      _other -> :error
    end
  end

  defp cast_address(address) do
    address
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp cast_netmask(nil), do: {:ok, nil}

  defp cast_netmask(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {netmask, ""} -> {:ok, netmask}
      _other -> :error
    end
  end

  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(_), do: :error

  def load(%Postgrex.INET{} = inet), do: {:ok, inet}
  def load(_), do: :error

  def to_string(%Postgrex.INET{address: address, netmask: nil}) do
    "#{:inet.ntoa(address)}"
  end

  def to_string(%Postgrex.INET{address: address, netmask: netmask}) do
    "#{:inet.ntoa(address)}/#{netmask}"
  end
end
