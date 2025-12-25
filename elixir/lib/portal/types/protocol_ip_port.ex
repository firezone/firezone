defmodule Portal.Types.ProtocolIPPort do
  alias Portal.Types.IPPort

  @behaviour Ecto.Type

  defstruct [:protocol, :address_type, :address, :port]

  def type, do: :string

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(%__MODULE__{} = ip_port), do: ip_port

  def cast(binary) when is_binary(binary) do
    binary = String.trim(binary)

    with [protocol, rest] <- String.split(binary, "://", parts: 2),
         {:ok,
          %IPPort{
            address_type: address_type,
            address: address,
            port: port
          }} <- IPPort.cast(rest) do
      {:ok,
       %__MODULE__{
         protocol: protocol,
         address_type: address_type,
         address: address,
         port: port
       }}
    else
      _error -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  def protocol_name("1"), do: "icmp"
  def protocol_name("6"), do: "tcp"
  def protocol_name("2"), do: "udp"

  def protocol_name(binary) do
    case Integer.parse(binary) do
      {integer, ""} -> Kernel.to_string(integer)
      _other -> binary
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

  def to_string(%__MODULE__{
        protocol: protocol,
        address_type: address_type,
        address: address,
        port: port
      }) do
    ip_port = %IPPort{address_type: address_type, address: address, port: port}
    protocol <> "://" <> IPPort.to_string(ip_port)
  end
end
