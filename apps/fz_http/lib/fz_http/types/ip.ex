defmodule FzHttp.Types.IP do
  @behaviour Ecto.Type

  defstruct [:address, :port]

  def type, do: :string

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

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

  def to_string(%__MODULE__{address: address, port: nil}),
    do: "#{:inet.ntoa(address)}"

  def to_string(%__MODULE__{address: address, port: port}),
    do: "#{:inet.ntoa(address)}:#{port}"
end
