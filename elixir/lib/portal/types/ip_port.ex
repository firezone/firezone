defmodule Portal.Types.IPPort do
  @behaviour Ecto.Type

  defstruct [:address_type, :address, :port]

  def type, do: :string

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(%__MODULE__{} = ip_port), do: ip_port

  def cast(binary) when is_binary(binary) do
    binary = String.trim(binary)

    with {:ok, {binary_address, binary_port}} <- parse_binary(binary),
         {:ok, address} <- cast_address(binary_address),
         {:ok, port} <- cast_port(binary_port) do
      address_type = Portal.Types.IP.type(address)
      {:ok, %__MODULE__{address_type: address_type, address: address, port: port}}
    else
      _error -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  defp parse_binary("[" <> binary) do
    with [binary_address, binary_port] <- String.split(binary, "]:", parts: 2) do
      {:ok, {binary_address, binary_port}}
    else
      [binary_address] -> {:ok, {binary_address, nil}}
    end
  end

  defp parse_binary(binary) do
    with [binary_address, binary_port] <- String.split(binary, ":") do
      {:ok, {binary_address, binary_port}}
    else
      _other -> {:ok, {binary, nil}}
    end
  end

  def cast_address(address) do
    address
    |> String.to_charlist()
    |> :inet.parse_strict_address()
  end

  defp cast_port(nil), do: {:ok, nil}

  defp cast_port(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {port, ""} when 0 < port and port <= 65_535 -> {:ok, port}
      _other -> :error
    end
  end

  def dump(%__MODULE__{} = ip) do
    {:ok, __MODULE__.to_string(ip)}
  end

  def dump(_), do: :error

  def load(binary) when is_binary(binary) do
    cast(binary)
  end

  def load(%__MODULE__{} = struct) do
    {:ok, struct}
  end

  def load(_), do: :error

  def to_string(%__MODULE__{address: ip, port: nil}) do
    ip |> :inet.ntoa() |> List.to_string()
  end

  def to_string(%__MODULE__{address_type: :ipv4, address: ip, port: port}) do
    ip = ip |> :inet.ntoa() |> List.to_string()
    "#{ip}:#{port}"
  end

  def to_string(%__MODULE__{address_type: :ipv6, address: ip, port: port}) do
    ip = ip |> :inet.ntoa() |> List.to_string()
    "[#{ip}]:#{port}"
  end

  def put_default_port(ip_port, default_port) do
    port = ip_port.port || default_port
    %{ip_port | port: port}
  end
end
