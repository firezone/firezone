defimpl String.Chars, for: Postgrex.INET do
  def to_string(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end

defimpl Phoenix.HTML.Safe, for: Postgrex.INET do
  def to_iodata(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end

defimpl String.Chars, for: FzHttp.Types.IPPort do
  def to_string(%FzHttp.Types.IPPort{} = ip_port), do: FzHttp.Types.IPPort.to_string(ip_port)
end

defimpl Phoenix.HTML.Safe, for: FzHttp.Types.IPPort do
  def to_iodata(%FzHttp.Types.IPPort{} = ip_port), do: FzHttp.Types.IPPort.to_string(ip_port)
end
