defimpl Phoenix.HTML.Safe, for: Postgrex.INET do
  def to_iodata(%Postgrex.INET{} = inet), do: Domain.Types.INET.to_string(inet)
end

defimpl Phoenix.HTML.Safe, for: Domain.Types.IPPort do
  def to_iodata(%Domain.Types.IPPort{} = ip_port), do: Domain.Types.IPPort.to_string(ip_port)
end
