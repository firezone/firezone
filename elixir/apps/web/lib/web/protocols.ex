defimpl Phoenix.HTML.Safe, for: Postgrex.INET do
  def to_iodata(%Postgrex.INET{} = inet), do: Domain.Types.INET.to_string(inet)
end

defimpl Phoenix.HTML.Safe, for: Domain.Types.IPPort do
  def to_iodata(%Domain.Types.IPPort{} = ip_port), do: Domain.Types.IPPort.to_string(ip_port)
end

defimpl Phoenix.HTML.Safe, for: Domain.Types.ProtocolIPPort do
  def to_iodata(%Domain.Types.ProtocolIPPort{} = struct),
    do: Domain.Types.ProtocolIPPort.to_string(struct)
end

defimpl Phoenix.Param, for: Domain.Account do
  def to_param(%Domain.Account{slug: slug}) when not is_nil(slug), do: slug
  def to_param(%Domain.Account{id: id}), do: id
end
