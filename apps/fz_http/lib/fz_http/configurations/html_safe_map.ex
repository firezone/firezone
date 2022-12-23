defimpl Phoenix.HTML.Safe, for: Map do
  def to_iodata(%{} = map) do
    Jason.encode_to_iodata!(map, pretty: true)
  end
end
