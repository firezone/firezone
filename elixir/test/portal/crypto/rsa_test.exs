defmodule Portal.Crypto.RSATest do
  use ExUnit.Case, async: true
  alias Portal.Crypto.RSA

  describe "generate/0" do
    test "generates RSA keypair with default 2048 bits" do
      keypair = RSA.generate()

      # Verify return structure and types
      assert is_map(keypair)
      assert is_tuple(keypair.private)
      assert is_tuple(keypair.public)
      assert is_binary(keypair.private_pem)
      assert is_binary(keypair.public_pem)
      assert is_binary(keypair.private_der)
      assert is_binary(keypair.public_der)

      # Verify the modulus is exactly 2048 bits
      {:RSAPublicKey, n, _e} = keypair.public
      modulus_bits = n |> :binary.encode_unsigned() |> bit_size()

      assert modulus_bits == 2048
    end

    test "private key is an RSAPrivateKey tuple" do
      keypair = RSA.generate()

      assert {:RSAPrivateKey, _v, _n, _e, _d, _p, _q, _e1, _e2, _coeff, _other} = keypair.private
    end

    test "public key is an RSAPublicKey tuple" do
      keypair = RSA.generate()

      assert {:RSAPublicKey, _n, _e} = keypair.public
    end

    test "public key modulus matches private key modulus" do
      keypair = RSA.generate()

      {:RSAPrivateKey, _v, priv_n, _e, _d, _p, _q, _e1, _e2, _coeff, _other} = keypair.private
      {:RSAPublicKey, pub_n, _e} = keypair.public

      assert priv_n == pub_n
    end

    test "public key exponent matches private key exponent" do
      keypair = RSA.generate()

      {:RSAPrivateKey, _v, _n, priv_e, _d, _p, _q, _e1, _e2, _coeff, _other} = keypair.private
      {:RSAPublicKey, _n, pub_e} = keypair.public

      assert priv_e == pub_e
    end

    test "public exponent is 65537" do
      keypair = RSA.generate()

      {:RSAPublicKey, _n, e} = keypair.public

      assert e == 65_537
    end

    test "private_pem is valid PEM format" do
      keypair = RSA.generate()

      assert is_binary(keypair.private_pem)
      assert String.starts_with?(keypair.private_pem, "-----BEGIN RSA PRIVATE KEY-----")
      assert String.contains?(keypair.private_pem, "-----END RSA PRIVATE KEY-----")
    end

    test "public_pem is valid PEM format" do
      keypair = RSA.generate()

      assert is_binary(keypair.public_pem)
      assert String.starts_with?(keypair.public_pem, "-----BEGIN PUBLIC KEY-----")
      assert String.contains?(keypair.public_pem, "-----END PUBLIC KEY-----")
    end

    test "private_der is binary" do
      keypair = RSA.generate()

      assert is_binary(keypair.private_der)
      assert byte_size(keypair.private_der) > 0
    end

    test "public_der is binary" do
      keypair = RSA.generate()

      assert is_binary(keypair.public_der)
      assert byte_size(keypair.public_der) > 0
    end

    test "private_pem can be decoded back to private key" do
      keypair = RSA.generate()

      [entry] = :public_key.pem_decode(keypair.private_pem)
      decoded_key = :public_key.pem_entry_decode(entry)

      assert {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = decoded_key
    end

    test "public_pem can be decoded back to public key" do
      keypair = RSA.generate()

      [entry] = :public_key.pem_decode(keypair.public_pem)
      decoded_key = :public_key.pem_entry_decode(entry)

      assert {:RSAPublicKey, _, _} = decoded_key
    end

    test "private_der can be decoded back to private key" do
      keypair = RSA.generate()

      decoded_key = :public_key.der_decode(:RSAPrivateKey, keypair.private_der)

      assert {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = decoded_key
      assert decoded_key == keypair.private
    end

    test "public_der can be decoded back to public key" do
      keypair = RSA.generate()

      decoded_key = :public_key.der_decode(:RSAPublicKey, keypair.public_der)

      assert {:RSAPublicKey, _, _} = decoded_key
      assert decoded_key == keypair.public
    end

    test "generates unique keypairs on each invocation" do
      keypair1 = RSA.generate()
      keypair2 = RSA.generate()

      refute keypair1.private_pem == keypair2.private_pem
      refute keypair1.public_pem == keypair2.public_pem
    end
  end

  describe "generate/1" do
    test "generates keypair with custom bit size" do
      for bits <- [1024, 2048, 4096] do
        keypair = RSA.generate(bits)

        assert is_map(keypair)
        assert Map.has_key?(keypair, :private)
        assert Map.has_key?(keypair, :public)
        assert String.starts_with?(keypair.private_pem, "-----BEGIN RSA PRIVATE KEY-----")

        # Verify the modulus size matches requested bits exactly
        {:RSAPublicKey, n, _e} = keypair.public
        modulus_bits = n |> :binary.encode_unsigned() |> bit_size()

        assert modulus_bits == bits
      end
    end
  end

  describe "key cryptographic properties" do
    test "generated keys can be used for encryption and decryption" do
      keypair = RSA.generate()
      plaintext = "test message"

      # Encrypt with public key
      ciphertext = :public_key.encrypt_public(plaintext, keypair.public)

      # Decrypt with private key
      decrypted = :public_key.decrypt_private(ciphertext, keypair.private)

      assert decrypted == plaintext
    end

    test "generated keys can be used for signing and verification" do
      keypair = RSA.generate()
      message = "test message"
      digest = :crypto.hash(:sha256, message)

      # Sign with private key
      signature = :public_key.sign(digest, :sha256, keypair.private)

      # Verify with public key
      assert :public_key.verify(digest, :sha256, signature, keypair.public)
    end

    test "signature verification fails with wrong public key" do
      keypair1 = RSA.generate()
      keypair2 = RSA.generate()
      message = "test message"
      digest = :crypto.hash(:sha256, message)

      # Sign with keypair1's private key
      signature = :public_key.sign(digest, :sha256, keypair1.private)

      # Verify with keypair2's public key should fail
      refute :public_key.verify(digest, :sha256, signature, keypair2.public)
    end

    test "decryption fails with wrong private key" do
      keypair1 = RSA.generate()
      keypair2 = RSA.generate()
      plaintext = "test message"

      # Encrypt with keypair1's public key
      ciphertext = :public_key.encrypt_public(plaintext, keypair1.public)

      # Decrypt with keypair2's private key should fail
      assert_raise ErlangError, fn ->
        :public_key.decrypt_private(ciphertext, keypair2.private)
      end
    end
  end
end
