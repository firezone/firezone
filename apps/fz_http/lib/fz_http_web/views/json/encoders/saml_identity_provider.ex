defimpl Jason.Encoder, for: FzHttp.Configurations.Configuration.SAMLIdentityProvider do
  def encode(%FzHttp.Configurations.Configuration.SAMLIdentityProvider{} = struct, opts) do
    Jason.Encode.map(struct, opts)
  end
end
