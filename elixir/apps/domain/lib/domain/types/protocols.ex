defimpl String.Chars, for: Postgrex.INET do
  def to_string(%Postgrex.INET{} = inet), do: Domain.Types.INET.to_string(inet)
end

defimpl JSON.Encoder, for: Postgrex.INET do
  def encode(%Postgrex.INET{} = struct, _opts) do
    "\"#{struct}\""
  end
end

defimpl String.Chars, for: Domain.Types.IPPort do
  def to_string(%Domain.Types.IPPort{} = ip_port), do: Domain.Types.IPPort.to_string(ip_port)
end

defimpl String.Chars, for: Domain.Types.ProtocolIPPort do
  def to_string(%Domain.Types.ProtocolIPPort{} = struct),
    do: Domain.Types.ProtocolIPPort.to_string(struct)
end
