defimpl String.Chars, for: Postgrex.INET do
  def to_string(%Postgrex.INET{} = inet), do: Portal.Types.INET.to_string(inet)
end

defimpl JSON.Encoder, for: Postgrex.INET do
  def encode(%Postgrex.INET{} = struct, _opts) do
    "\"#{struct}\""
  end
end

defimpl String.Chars, for: Portal.Types.IPPort do
  def to_string(%Portal.Types.IPPort{} = ip_port), do: Portal.Types.IPPort.to_string(ip_port)
end

defimpl String.Chars, for: Portal.Types.ProtocolIPPort do
  def to_string(%Portal.Types.ProtocolIPPort{} = struct),
    do: Portal.Types.ProtocolIPPort.to_string(struct)
end
