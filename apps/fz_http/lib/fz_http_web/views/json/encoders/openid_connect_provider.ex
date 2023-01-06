defimpl Jason.Encoder, for: FzHttp.Configurations.Configuration.OpenIDConnectProvider do
  def encode(%FzHttp.Configurations.Configuration.OpenIDConnectProvider{} = struct, opts) do
    Jason.Encode.map(struct, opts)
  end
end
