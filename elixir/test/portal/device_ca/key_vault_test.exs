defmodule Portal.DeviceCA.KeyVaultTest do
  use Portal.DataCase, async: true
  import ExUnit.CaptureLog
  import Plug.Conn
  import Portal.AccountFixtures

  alias Portal.DeviceCA

  @vault_url "https://device-ca.vault.example.test"

  setup do
    Portal.Config.put_env_override(:device_ca_key_storage, :azure)
    Portal.Config.put_env_override(:device_ca_key_vault_url, @vault_url)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{"access_token" => "vault-token", "expires_on" => "4102444800"})
    end)

    {:ECPrivateKey, _, _, parameters, point, _} =
      private_key = :public_key.generate_key({:namedCurve, :secp256r1})

    %{public_key: {{:ECPoint, point}, parameters}, private_key: private_key}
  end

  test "creates a CA whose key stays in the vault", %{public_key: public_key, private_key: private_key} do
    account = account_fixture()
    key_id = "#{@vault_url}/keys/device-ca-#{account.id}/v1"
    test_pid = self()

    Req.Test.stub(DeviceCA.KeyVault, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {conn.method, conn.request_path, Jason.decode!(body), get_req_header(conn, "authorization")})

      case conn.request_path do
        "/keys/device-ca-" <> _rest = path ->
          if String.ends_with?(path, "/create") do
            Req.Test.json(conn, %{
              "key" => jwk(key_id, public_key)
            })
          else
            digest = Base.url_decode64!(Jason.decode!(body)["value"], padding: false)
            Req.Test.json(conn, %{"kid" => key_id, "value" => b64(raw_signature(digest, private_key))})
          end
      end
    end)

    assert {:ok, ca} = DeviceCA.ensure(account.id)
    assert ca.key_id == key_id
    assert ca.private_key == nil

    assert :public_key.pkix_verify(ca.certificate, public_key)

    create_path = "/keys/device-ca-#{account.id}/create"
    assert_received {"POST", ^create_path, create, ["Bearer vault-token"]}
    assert create["kty"] == "EC"
    assert create["crv"] == "P-256"
    assert create["attributes"] == %{"exportable" => false}

    sign_path = "/keys/device-ca-#{account.id}/v1/sign"
    assert_received {"POST", ^sign_path, %{"alg" => "ES256"}, ["Bearer vault-token"]}
  end

  test "deletes the new key when the account is gone", %{public_key: public_key, private_key: private_key} do
    account_id = Ecto.UUID.generate()
    key_id = "#{@vault_url}/keys/device-ca-#{account_id}/v1"
    test_pid = self()

    Req.Test.stub(DeviceCA.KeyVault, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {conn.method, conn.request_path})

      cond do
        conn.method == "DELETE" ->
          Req.Test.json(conn, %{})

        String.ends_with?(conn.request_path, "/create") ->
          Req.Test.json(conn, %{"key" => jwk(key_id, public_key)})

        true ->
          digest = Base.url_decode64!(Jason.decode!(body)["value"], padding: false)
          Req.Test.json(conn, %{"kid" => key_id, "value" => b64(raw_signature(digest, private_key))})
      end
    end)

    assert {:error, %Ecto.Changeset{}} = DeviceCA.ensure(account_id)

    delete_path = "/keys/device-ca-#{account_id}"
    assert_received {"DELETE", ^delete_path}
  end

  test "refuses a signature that does not match the key", %{public_key: public_key} do
    account = account_fixture()
    key_id = "#{@vault_url}/keys/device-ca-#{account.id}/v1"
    other_key = :public_key.generate_key({:namedCurve, :secp256r1})

    Req.Test.stub(DeviceCA.KeyVault, fn conn ->
      {:ok, body, conn} = read_body(conn)

      if String.ends_with?(conn.request_path, "/create") do
        Req.Test.json(conn, %{"key" => jwk(key_id, public_key)})
      else
        digest = Base.url_decode64!(Jason.decode!(body)["value"], padding: false)
        Req.Test.json(conn, %{"kid" => key_id, "value" => b64(raw_signature(digest, other_key))})
      end
    end)

    assert DeviceCA.ensure(account.id) == {:error, :bad_signature}
    refute Repo.get_by(Portal.DeviceCertificateAuthority, account_id: account.id)
  end

  test "reaches the vault at a private address" do
    test_pid = self()
    Portal.Config.delete_env_override(:portal, DeviceCA.KeyVault, [:req_opts, :plug])

    Portal.Config.merge_env_override(DeviceCA.KeyVault,
      req_opts: [
        adapter: fn request ->
          send(test_pid, {:allow_private_ips, request.options[:allow_private_ips]})
          {request, Req.Response.new(status: 404)}
        end
      ]
    )

    assert DeviceCA.delete_key(Ecto.UUID.generate()) == :ok
    assert_received {:allow_private_ips, true}
  end

  test "never sends the token outside the vault" do
    Req.Test.stub(DeviceCA.KeyVault, fn _conn -> flunk("unexpected request") end)

    assert DeviceCA.KeyVault.sign(%{key_id: "https://other.example.test/keys/a/1"}, :crypto.hash(:sha256, "")) ==
             {:error, :key_outside_vault}
  end

  test "reports a failed request as unavailable" do
    Req.Test.stub(DeviceCA.KeyVault, fn conn ->
      conn |> put_status(403) |> Req.Test.json(%{"error" => %{"code" => "Forbidden"}})
    end)

    log =
      capture_log(fn ->
        assert DeviceCA.ensure(account_fixture().id) == {:error, :unavailable}
      end)

    assert log =~ "Device CA Key Vault request failed"
  end

  test "deletes the key of an account, also when it is gone" do
    account_id = Ecto.UUID.generate()

    Req.Test.stub(DeviceCA.KeyVault, fn %{method: "DELETE"} = conn ->
      send_resp(conn, 404, "")
    end)

    assert DeviceCA.delete_key(account_id) == :ok
  end

  defp b64(value), do: Base.url_encode64(value, padding: false)

  defp jwk(key_id, {{:ECPoint, <<4, x::binary-size(32), y::binary-size(32)>>}, _parameters}),
    do: %{"kid" => key_id, "kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}

  # The vault returns r and s side by side, not DER encoded.
  defp raw_signature(digest, private_key) do
    {:"ECDSA-Sig-Value", r, s} =
      :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign({:digest, digest}, :sha256, private_key))

    <<r::unsigned-size(256), s::unsigned-size(256)>>
  end
end
