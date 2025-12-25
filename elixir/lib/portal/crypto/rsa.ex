defmodule Portal.Crypto.RSA do
  @moduledoc """
  Generate RSA keypairs using Erlang/OTP's :public_key.

  - `generate/1` returns PEM and DER for both private and public keys.
  """

  @default_bits 2048
  @public_exponent 65_537

  @type t :: %{
          private: :public_key.rsa_private_key(),
          public: :public_key.rsa_public_key(),
          private_pem: binary(),
          public_pem: binary(),
          private_der: binary(),
          public_der: binary()
        }

  @doc """
  Generate an RSA keypair.

  ## Options
    * `bits` — modulus size (default: 2048)

  ## Returns
    `%{private_pem, public_pem, private_der, public_der}`
  """
  @spec generate(pos_integer()) :: t()
  def generate(bits \\ @default_bits) do
    # Private key as an Erlang record tuple:
    # {:RSAPrivateKey, v, n, e, d, p, q, e1, e2, coeff, other}
    priv = :public_key.generate_key({:rsa, bits, @public_exponent})

    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _coeff, _other} = priv
    pub = {:RSAPublicKey, n, e}

    # DER encodings (raw ASN.1 DER)
    priv_der = :public_key.der_encode(:RSAPrivateKey, priv)
    pub_der = :public_key.der_encode(:RSAPublicKey, pub)

    # PEM entries (PKCS#1 for private; SPKI for public)
    priv_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPrivateKey, priv)
      ])

    pub_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, pub)
      ])

    %{
      private: priv,
      public: pub,
      private_pem: priv_pem,
      public_pem: pub_pem,
      private_der: priv_der,
      public_der: pub_der
    }
  end
end
