defimpl String.Chars, for: Postgrex.INET do
  def to_string(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end

defimpl Phoenix.HTML.Safe, for: Postgrex.INET do
  def to_iodata(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end
