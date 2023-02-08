defmodule FzHttp.Types.CIDR do
  @moduledoc """
  Ecto type implementation for CIDR's based on `Postgrex.INET` type, it required netmask to be always set.
  """
  @behaviour Ecto.Type

  def type, do: :inet

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(%Postgrex.INET{} = struct), do: {:ok, struct}

  def cast(binary) when is_binary(binary) do
    with {:ok, {binary_address, binary_netmask}} <- parse_binary(binary),
         {:ok, address} <- cast_address(binary_address),
         {:ok, netmask} <- cast_netmask(binary_netmask),
         :ok <- validate_netmask(address, netmask) do
      {:ok, %Postgrex.INET{address: address, netmask: netmask}}
    else
      _error -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  defp parse_binary(binary) do
    binary = String.trim(binary)

    with [binary_address, binary_netmask] <- String.split(binary, "/", parts: 2) do
      {:ok, {binary_address, binary_netmask}}
    else
      _other -> :error
    end
  end

  defp cast_address(address) do
    address
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp cast_netmask(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {netmask, ""} -> {:ok, netmask}
      _other -> :error
    end
  end

  defp validate_netmask(address, netmask)
       when tuple_size(address) == 4 and 0 <= netmask and netmask <= 32,
       do: :ok

  defp validate_netmask(address, netmask)
       when tuple_size(address) == 8 and 0 <= netmask and netmask <= 128,
       do: :ok

  defp validate_netmask(_address, _netmask), do: :error

  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(_), do: :error

  def load(%Postgrex.INET{} = inet), do: {:ok, inet}
  def load(_), do: :error

  def to_string(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end
