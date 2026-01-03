defmodule Portal.Crypto.JWK do
  alias Portal.Crypto.RSA

  @moduledoc """
  Generate a JOSE JWK (private) and a JWKS (public-only) from an RSA keypair.
  """

  @default_bits 2048

  @type jwk :: %{String.t() => String.t()}
  @type public_jwk :: %{String.t() => String.t()}
  @type jwks :: %{String.t() => [public_jwk()]}
  @type t :: %{jwk: jwk(), jwks: jwks(), kid: String.t()}

  @doc """
  Returns:
    * `:jwk` — private JWK (keep secret; use to sign)
    * `:jwks` — public JWKS map (share; use to publish)
    * `:kid` — key ID consistent with RFC 7638 thumbprint
  """
  @spec generate_jwk_and_jwks(pos_integer()) :: t()
  def generate_jwk_and_jwks(bits \\ @default_bits) do
    # Generate RSA keypair
    keypair = RSA.generate(bits)

    # Extract RSA components from the private key tuple
    {:RSAPrivateKey, _v, n, e, d, p, q, e1, e2, coeff, _other} = keypair.private

    # Create JWK (private key for signing)
    jwk = %{
      "kty" => "RSA",
      "alg" => "RS256",
      "use" => "sig",
      "n" => url_encode_int(n),
      "e" => url_encode_int(e),
      "d" => url_encode_int(d),
      "p" => url_encode_int(p),
      "q" => url_encode_int(q),
      "dp" => url_encode_int(e1),
      "dq" => url_encode_int(e2),
      "qi" => url_encode_int(coeff)
    }

    # Generate key ID using RFC 7638 thumbprint
    thumbprint_json =
      JSON.encode!(%{
        "e" => jwk["e"],
        "kty" => jwk["kty"],
        "n" => jwk["n"]
      })

    kid = :crypto.hash(:sha256, thumbprint_json) |> Base.url_encode64(padding: false)

    # Add kid to JWK
    jwk = Map.put(jwk, "kid", kid)

    # Create JWKS (public key set for verification)
    public_jwk = %{
      "kty" => "RSA",
      "alg" => "RS256",
      "use" => "sig",
      "kid" => kid,
      "n" => jwk["n"],
      "e" => jwk["e"]
    }

    jwks = %{
      "keys" => [public_jwk]
    }

    %{
      jwk: jwk,
      jwks: jwks,
      kid: kid
    }
  end

  @spec extract_public_key_components(jwk()) :: public_jwk()
  def extract_public_key_components(private_jwk) do
    %{
      "kty" => private_jwk["kty"],
      "alg" => private_jwk["alg"],
      "use" => private_jwk["use"],
      "kid" => private_jwk["kid"],
      "n" => private_jwk["n"],
      "e" => private_jwk["e"]
    }
  end

  @spec url_encode_int(non_neg_integer()) :: String.t()
  defp url_encode_int(int) when is_integer(int) do
    int
    |> int_to_bin()
    |> Base.url_encode64(padding: false)
  end

  # Helper function to convert integer to binary
  @spec int_to_bin(non_neg_integer()) :: binary()
  defp int_to_bin(int) when is_integer(int) do
    # Convert integer to minimal binary representation
    hex_string = Integer.to_string(int, 16)
    # Ensure even number of hex digits
    hex_string =
      if rem(String.length(hex_string), 2) == 1, do: "0" <> hex_string, else: hex_string

    Base.decode16!(hex_string, case: :mixed)
  end
end
