defmodule PortalAPI.DeviceCertificateControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.TokenFixtures

  alias Portal.DeviceCA

  setup do
    %{account: account_fixture()}
  end

  describe "create/2" do
    test "issues a certificate for a Client token", %{conn: conn, account: account} do
      token = client_token_fixture(account: account)
      {point, private_key} = device_key()

      conn = request(conn, encode_token(token), csr(point, private_key))

      assert %{"certificate" => certificate, "ca_certificate" => ca_certificate} = json_response(conn, 200)
      {:ok, ca} = DeviceCA.ensure(account.id)
      assert ca_certificate == Portal.Crypto.X509.pem_encode(ca.certificate)
      assert {:ok, _result} = :public_key.pkix_path_validation(ca.certificate, [der(certificate)], [])
    end

    test "issues a certificate for a Gateway token", %{conn: conn, account: account} do
      token = gateway_token_fixture(account: account)
      {point, private_key} = device_key()

      conn = request(conn, encode_gateway_token(token), csr(point, private_key))

      assert %{"certificate" => certificate} = json_response(conn, 200)
      {:ok, ca} = DeviceCA.ensure(account.id)
      assert {:ok, _result} = :public_key.pkix_path_validation(ca.certificate, [der(certificate)], [])
    end

    test "refuses a missing or invalid token", %{conn: conn} do
      {point, private_key} = device_key()

      assert %{"code" => "missing_token"} =
               conn |> post("/device/certificate", %{csr: csr(point, private_key)}) |> json_response(401)

      assert %{"code" => "invalid_token"} =
               conn |> request("not-a-token", csr(point, private_key)) |> json_response(401)
    end

    test "refuses a CSR that does not prove the key", %{conn: conn, account: account} do
      token = encode_token(client_token_fixture(account: account))
      {point, _private_key} = device_key()
      {_other_point, other_key} = device_key()

      assert %{"code" => "invalid_csr"} = conn |> request(token, csr(point, other_key)) |> json_response(400)
      assert %{"code" => "invalid_csr"} = conn |> request(token, "%%%") |> json_response(400)
    end

    test "limits certificates per token", %{conn: conn, account: account} do
      Portal.Config.merge_env_override(PortalAPI.DeviceCertificateController, token_capacity: 1)
      token = encode_token(client_token_fixture(account: account))
      {point, private_key} = device_key()

      assert conn |> request(token, csr(point, private_key)) |> json_response(200)

      conn = request(conn, token, csr(point, private_key))
      assert json_response(conn, 429)
      assert [_retry_after] = get_resp_header(conn, "retry-after")
    end

    test "limits certificates per account", %{conn: conn, account: account} do
      Portal.Config.merge_env_override(PortalAPI.DeviceCertificateController,
        account_capacity: 1,
        account_refill_rate: 1
      )

      {point, private_key} = device_key()
      csr = csr(point, private_key)
      first_token = encode_token(client_token_fixture(account: account))
      second_token = encode_token(client_token_fixture(account: account))

      assert conn |> request(first_token, csr) |> json_response(200)
      assert conn |> request(second_token, csr) |> json_response(429)
    end

    test "asks the device to wait when the vault is busy", %{conn: conn, account: account} do
      insert_vault_ca(account)
      Portal.Config.put_env_override(:device_ca_key_storage, :azure)
      Portal.Config.put_env_override(:device_ca_key_vault_url, "https://device-ca.vault.example.test")

      Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{"access_token" => "vault-token", "expires_on" => "4102444800"})
      end)

      Req.Test.stub(DeviceCA.KeyVault, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => %{"code" => "Throttled"}})
      end)

      {point, private_key} = device_key()
      conn = request(conn, encode_token(client_token_fixture(account: account)), csr(point, private_key))

      assert json_response(conn, 429)
      assert get_resp_header(conn, "retry-after") == ["10"]
    end
  end

  defp request(conn, token, csr) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/device/certificate", %{csr: csr})
  end

  defp der(pem), do: pem |> :public_key.pem_decode() |> hd() |> elem(1)

  # A CA whose key lives in the vault, without asking the vault to create one.
  defp insert_vault_ca(account) do
    {:ok, ca} = DeviceCA.ensure(account.id)

    ca
    |> Ecto.Changeset.change(key_id: "https://device-ca.vault.example.test/keys/device-ca-#{account.id}/v1", private_key: nil)
    |> Repo.update!()
  end

  defp device_key do
    {:ECPrivateKey, _, _, _, point, _} = private_key = :public_key.generate_key({:namedCurve, :secp256r1})
    {point, private_key}
  end

  defp csr(point, private_key) do
    info =
      {:CertificationRequestInfo, :v1, {:rdnSequence, []},
       {:CertificationRequestInfo_subjectPKInfo,
        {:CertificationRequestInfo_subjectPKInfo_algorithm, {1, 2, 840, 10_045, 2, 1},
         {:asn1_OPENTYPE, :public_key.der_encode(:EcpkParameters, {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})}},
        point}, []}

    signature = :public_key.sign(:public_key.der_encode(:CertificationRequestInfo, info), :sha256, private_key)

    :public_key.der_encode(
      :CertificationRequest,
      {:CertificationRequest, info, {:CertificationRequest_signatureAlgorithm, {1, 2, 840, 10_045, 4, 3, 2}, :asn1_NOVALUE},
       signature}
    )
    |> Base.encode64()
  end
end
