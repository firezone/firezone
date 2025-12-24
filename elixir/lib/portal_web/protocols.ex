defimpl Phoenix.HTML.Safe, for: Postgrex.INET do
  def to_iodata(%Postgrex.INET{} = inet), do: Portal.Types.INET.to_string(inet)
end

defimpl Phoenix.HTML.Safe, for: Portal.Types.IPPort do
  def to_iodata(%Portal.Types.IPPort{} = ip_port), do: Portal.Types.IPPort.to_string(ip_port)
end

defimpl Phoenix.HTML.Safe, for: Portal.Types.ProtocolIPPort do
  def to_iodata(%Portal.Types.ProtocolIPPort{} = struct),
    do: Portal.Types.ProtocolIPPort.to_string(struct)
end

defimpl Phoenix.Param, for: Portal.Account do
  def to_param(%Portal.Account{slug: slug}) when not is_nil(slug), do: slug
  def to_param(%Portal.Account{id: id}), do: id
end
