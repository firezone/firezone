defmodule Domain.Crypto.JWK do
  @spec generate_private_key() :: String.t()
  def generate_private_key do
    # Okta requires RSA
    jwk =
      JOSE.JWK.generate_key({:rsa, 2048})
      |> JOSE.JWK.merge(%{"kid" => Ecto.UUID.generate(), "use" => "sig"})

    {_metadata, private_key} = JOSE.JWK.to_map(jwk)

    Jason.encode!(private_key)
  end

  @spec public_key(String.t()) :: String.t()
  def public_key(private_key_json) do
    map = Jason.decode!(private_key_json)
    jwk = JOSE.JWK.from_map(map)

    {_, public_key} = JOSE.JWK.to_public_map(jwk)

    Jason.encode!(public_key)
  end
end
