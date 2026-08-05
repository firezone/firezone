defmodule Portal.WebAuthnFixtures do
  @moduledoc """
  Software WebAuthn authenticator for tests.

  Generates a P-256 keypair and produces registration attestations and
  authentication assertions in the wire format Portal.Crypto.WebAuthn verifies,
  including a minimal CBOR encoder so tests stay dependency-free too.
  """

  def generate_authenticator do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public_key

    %{
      credential_id: :crypto.strong_rand_bytes(32),
      private_key: private_key,
      cose_key: %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
    }
  end

  def challenge_stub(bytes) do
    %{bytes: bytes, origin: Portal.Crypto.WebAuthn.origin(), rp_id: Portal.Crypto.WebAuthn.rp_id()}
  end

  def registration_response(authenticator, challenge, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, 0)
    flags = Keyword.get(opts, :flags, 0x45)

    cose_key_cbor =
      cbor_encode(%{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => {:bytes, authenticator.cose_key[-2]},
        -3 => {:bytes, authenticator.cose_key[-3]}
      })

    auth_data =
      :crypto.hash(:sha256, challenge.rp_id) <>
        <<flags>> <>
        <<sign_count::unsigned-big-integer-size(32)>> <>
        <<0::128>> <>
        <<byte_size(authenticator.credential_id)::unsigned-big-integer-size(16)>> <>
        authenticator.credential_id <>
        cose_key_cbor

    attestation_object =
      cbor_encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => {:bytes, auth_data}
      })

    %{
      attestation_object: attestation_object,
      client_data_json: client_data_json("webauthn.create", challenge)
    }
  end

  def assertion_response(authenticator, challenge, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, 1)
    flags = Keyword.get(opts, :flags, 0x05)
    client_data_json = Keyword.get(opts, :client_data_json, client_data_json("webauthn.get", challenge))

    authenticator_data =
      :crypto.hash(:sha256, challenge.rp_id) <>
        <<flags>> <>
        <<sign_count::unsigned-big-integer-size(32)>>

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        authenticator_data <> :crypto.hash(:sha256, client_data_json),
        [authenticator.private_key, :secp256r1]
      )

    %{
      credential_id: authenticator.credential_id,
      authenticator_data: authenticator_data,
      signature: signature,
      client_data_json: client_data_json
    }
  end

  def encode_assertion_params(assertion) do
    %{
      "credential_id" => Base.url_encode64(assertion.credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(assertion.authenticator_data, padding: false),
      "signature" => Base.url_encode64(assertion.signature, padding: false),
      "client_data_json" => Base.url_encode64(assertion.client_data_json, padding: false)
    }
  end

  def cbor_encode(integer) when is_integer(integer) and integer >= 0,
    do: cbor_head(0, integer)

  def cbor_encode(integer) when is_integer(integer),
    do: cbor_head(1, -1 - integer)

  def cbor_encode({:bytes, binary}) when is_binary(binary),
    do: cbor_head(2, byte_size(binary)) <> binary

  def cbor_encode(string) when is_binary(string),
    do: cbor_head(3, byte_size(string)) <> string

  def cbor_encode(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> cbor_encode(key) <> cbor_encode(value) end)
    |> Enum.reduce(cbor_head(5, map_size(map)), &(&2 <> &1))
  end

  defp cbor_head(major, value) when value < 24, do: <<major::3, value::5>>
  defp cbor_head(major, value) when value < 256, do: <<major::3, 24::5, value::unsigned-big-8>>

  defp cbor_head(major, value) when value < 65_536,
    do: <<major::3, 25::5, value::unsigned-big-16>>

  defp cbor_head(major, value), do: <<major::3, 26::5, value::unsigned-big-32>>

  defp client_data_json(type, challenge) do
    JSON.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge.bytes, padding: false),
      "origin" => challenge.origin
    })
  end
end
