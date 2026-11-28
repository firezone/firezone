defmodule Portal.DeviceCAFixtures do
  @moduledoc """
  Device keys and certificates from an account's device CA.
  """

  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @ecdsa_with_sha256 {1, 2, 840, 10_045, 4, 3, 2}

  @doc "A new P-256 device key, and the hash that identifies it."
  def device_key do
    {:ECPrivateKey, _, _, _, point, _} = private_key = :public_key.generate_key({:namedCurve, :secp256r1})
    %{point: point, private_key: private_key, key_hash: Portal.DeviceCA.key_hash(point)}
  end

  @doc "A DER certificate for the key from the account's device CA."
  def device_certificate(account, key \\ device_key()) do
    {:ok, %{certificate: certificate}} = Portal.DeviceCA.issue(account.id, csr(key))
    certificate
  end

  defp csr(%{point: point, private_key: private_key}) do
    info =
      {:CertificationRequestInfo, :v1, {:rdnSequence, []},
       {:CertificationRequestInfo_subjectPKInfo,
        {:CertificationRequestInfo_subjectPKInfo_algorithm, @ec_public_key,
         {:asn1_OPENTYPE, :public_key.der_encode(:EcpkParameters, {:namedCurve, @p256})}}, point}, []}

    signature = :public_key.sign(:public_key.der_encode(:CertificationRequestInfo, info), :sha256, private_key)

    :public_key.der_encode(
      :CertificationRequest,
      {:CertificationRequest, info, {:CertificationRequest_signatureAlgorithm, @ecdsa_with_sha256, :asn1_NOVALUE},
       signature}
    )
  end
end
