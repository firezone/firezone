defmodule FzHttp.Types.IPPort do
  @behaviour Ecto.Type

  defstruct [:address, :port]

  def type, do: :string

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(binary) when is_binary(binary) do
    with {:ok, {binary_address, binary_port}} <- parse_binary(binary),
         {:ok, address} <- cast_address(binary_address),
         {:ok, port} <- cast_port(binary_port) do
      {:ok, %__MODULE__{address: address, port: port}}
    else
      _error -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  defp parse_binary(binary) do
    binary = String.trim(binary)

    with [binary_address, binary_port] <- String.split(binary, ":", parts: 2) do
      {:ok, {binary_address, binary_port}}
    else
      [binary_address] -> {:ok, {binary_address, nil}}
    end
  end

  def cast_address(address) do
    address
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp cast_port(nil), do: {:ok, nil}

  defp cast_port(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {port, ""} when 0 < port and port <= 65_535 -> {:ok, port}
      _other -> :error
    end
  end

  def dump(%__MODULE__{} = ip) do
    address = ip.address |> :inet.ntoa() |> to_string()
    {:ok, "#{address}:#{ip.port}"}
  end

  def dump(_), do: :error

  def load(%__MODULE__{} = ip) do
    {:ok, ip}
  end

  def load(_), do: :error
end
