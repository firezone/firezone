defmodule FzHttp.Types.IP do
  @moduledoc """
  Ecto type implementation for IP's based on `Postgrex.INET` type,
  it always ignores netmask by setting it to `nil`.
  """
  @behaviour Ecto.Type

  def type, do: :inet

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(%Postgrex.INET{} = inet), do: {:ok, inet}

  def cast(binary) when is_binary(binary) do
    with {:ok, address} <- FzHttp.Types.IPPort.cast_address(binary) do
      {:ok, %Postgrex.INET{address: address, netmask: nil}}
    else
      {:error, _reason} -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(_), do: :error

  def load(%Postgrex.INET{} = inet), do: {:ok, inet}
  def load(_), do: :error

  def to_string(ip) when is_binary(ip), do: ip
  def to_string(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end
