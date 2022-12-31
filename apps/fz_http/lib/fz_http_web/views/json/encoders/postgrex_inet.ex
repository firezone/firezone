defimpl Jason.Encoder, for: Postgrex.INET do
  def encode(%Postgrex.INET{} = struct, opts) do
    Jason.Encode.string("#{struct}", opts)
  end
end
