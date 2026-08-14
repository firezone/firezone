defmodule Portal.Crypto.WebAuthnTest do
  use Portal.DataCase, async: true

  import Portal.WebAuthnFixtures

  describe "verify_registration/3" do
    test "accepts a registration from the software authenticator" do
      authenticator = generate_authenticator()
      challenge = Portal.Crypto.WebAuthn.registration_challenge()
      response = registration_response(authenticator, challenge)

      assert {:ok, passkey} =
               Portal.Crypto.WebAuthn.verify_registration(
                 challenge,
                 response.attestation_object,
                 response.client_data_json
               )

      assert passkey.credential_id == authenticator.credential_id
      assert Portal.Crypto.WebAuthn.decode_cose_key(passkey.public_key) == authenticator.cose_key
      assert passkey.sign_count == 0
    end

    test "rejects a registration against a different challenge" do
      authenticator = generate_authenticator()
      challenge = Portal.Crypto.WebAuthn.registration_challenge()
      other_challenge = Portal.Crypto.WebAuthn.registration_challenge()
      response = registration_response(authenticator, other_challenge)

      assert {:error, _reason} =
               Portal.Crypto.WebAuthn.verify_registration(
                 challenge,
                 response.attestation_object,
                 response.client_data_json
               )
    end
  end

  describe "hardening checks" do
    test "rejects a registration without user verification" do
      authenticator = generate_authenticator()
      challenge = Portal.Crypto.WebAuthn.registration_challenge()
      response = registration_response(authenticator, challenge, flags: 0x41)

      assert {:error, :invalid_registration} =
               Portal.Crypto.WebAuthn.verify_registration(
                 challenge,
                 response.attestation_object,
                 response.client_data_json
               )
    end

    test "rejects an assertion without user verification" do
      authenticator = generate_authenticator()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      assertion = assertion_response(authenticator, challenge, flags: 0x01)

      assert {:error, :invalid_assertion} =
               Portal.Crypto.WebAuthn.verify_authentication(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end

    test "rejects backed-up credentials that are not backup eligible" do
      authenticator = generate_authenticator()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      assertion = assertion_response(authenticator, challenge, flags: 0x15)

      assert {:error, :invalid_assertion} =
               Portal.Crypto.WebAuthn.verify_authentication(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end

    test "rejects a cross-origin assertion" do
      authenticator = generate_authenticator()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      client_data_json =
        JSON.encode!(%{
          "type" => "webauthn.get",
          "challenge" => Base.url_encode64(challenge.bytes, padding: false),
          "origin" => challenge.origin,
          "crossOrigin" => true
        })

      assertion = assertion_response(authenticator, challenge, client_data_json: client_data_json)

      assert {:error, :invalid_assertion} =
               Portal.Crypto.WebAuthn.verify_authentication(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end

    test "rejects oversized credential ids" do
      authenticator =
        generate_authenticator()
        |> Map.put(:credential_id, :crypto.strong_rand_bytes(1200))

      challenge = Portal.Crypto.WebAuthn.registration_challenge()
      response = registration_response(authenticator, challenge)

      assert {:error, :invalid_registration} =
               Portal.Crypto.WebAuthn.verify_registration(
                 challenge,
                 response.attestation_object,
                 response.client_data_json
               )
    end
  end

  describe "CBOR decoder" do
    test "decodes the subset produced by authenticators" do
      encoded = cbor_encode(%{1 => 2, 3 => -7, "fmt" => "none", -2 => {:bytes, <<1, 2, 3>>}})

      assert {:ok, %{1 => 2, 3 => -7, "fmt" => "none", -2 => <<1, 2, 3>>}, ""} =
               Portal.Crypto.CBOR.decode(encoded)
    end

    test "rejects indefinite-length items" do
      assert :error = Portal.Crypto.CBOR.decode(<<0x5F, 0x41, 0x01, 0xFF>>)
    end

    test "rejects tags and floats" do
      assert :error = Portal.Crypto.CBOR.decode(<<0xC0, 0x00>>)
      assert :error = Portal.Crypto.CBOR.decode(<<0xF9, 0x00, 0x00>>)
    end

    test "rejects truncated input" do
      assert :error = Portal.Crypto.CBOR.decode(<<0x58, 0xFF, 0x01>>)
      assert :error = Portal.Crypto.CBOR.decode(<<0xA2, 0x01>>)
    end

    test "rejects duplicate map keys" do
      assert :error = Portal.Crypto.CBOR.decode(<<0xA2, 0x01, 0x02, 0x01, 0x03>>)
    end

    test "rejects deeply nested input" do
      nested = Enum.reduce(1..20, <<0x01>>, fn _depth, acc -> <<0x81>> <> acc end)
      assert :error = Portal.Crypto.CBOR.decode(nested)
    end
  end

  describe "verify_authentication/5" do
    test "accepts an assertion from the registered authenticator" do
      authenticator = generate_authenticator()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      assertion = assertion_response(authenticator, challenge, sign_count: 7)

      assert {:ok, auth_data} =
               Portal.Crypto.WebAuthn.verify_authentication(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )

      assert auth_data.sign_count == 7
    end

    test "rejects an assertion signed by a different key" do
      authenticator = generate_authenticator()
      other_authenticator = generate_authenticator()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      assertion =
        other_authenticator
        |> Map.put(:credential_id, authenticator.credential_id)
        |> assertion_response(challenge)

      assert {:error, _reason} =
               Portal.Crypto.WebAuthn.verify_authentication(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end

    test "rejects an assertion for an unknown credential id" do
      authenticator = generate_authenticator()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      assertion = assertion_response(authenticator, challenge)

      assert {:error, _reason} =
               Portal.Crypto.WebAuthn.verify_authentication(
                 :crypto.strong_rand_bytes(32),
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end
  end
end
