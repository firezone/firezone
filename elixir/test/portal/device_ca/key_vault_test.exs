defmodule Portal.DeviceCA.KeyVaultTest do
  use Portal.DataCase, async: true
  import ExUnit.CaptureLog
  import Plug.Conn
  import Portal.AccountFixtures

  alias Portal.DeviceCA

  @vault_url "https://device-ca.vault.example.test"

  setup do
    Portal.Config.put_env_override(:device_ca_key_vault_url, @vault_url)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{"access_token" => "vault-token", "expires_on" => "4102444800"})
    end)

    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public_key: public_key, private_key: private_key}
  end

  test "creates a CA whose key stays in the vault", %{public_key: public_key, private_key: private_key} do
    account = account_fixture()
    key_id = "#{@vault_url}/keys/device-ca-#{account.id}/v1"
    test_pid = self()
    <<4, x::binary-size(32), y::binary-size(32)>> = public_key

    Req.Test.stub(DeviceCA.KeyVault, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {conn.method, conn.request_path, Jason.decode!(body), get_req_header(conn, "authorization")})

      case conn.request_path do
        "/keys/device-ca-" <> _rest = path ->
          if String.ends_with?(path, "/create") do
            Req.Test.json(conn, %{"key" => %{"kid" => key_id, "x" => b64(x), "y" => b64(y)}})
          else
            digest = Base.url_decode64!(Jason.decode!(body)["value"], padding: false)
            der = :crypto.sign(:ecdsa, :sha256, {:digest, digest}, [private_key, :prime256v1])
            {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
            Req.Test.json(conn, %{"kid" => key_id, "value" => b64(<<r::256, s::256>>)})
          end
      end
    end)

    assert {:ok, ca} = DeviceCA.ensure(account.id)
    assert ca.key_id == key_id

    ec_params = {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}
    assert :public_key.pkix_verify(ca.certificate, {{:ECPoint, public_key}, ec_params})

    create_path = "/keys/device-ca-#{account.id}/create"
    assert_received {"POST", ^create_path, create, ["Bearer vault-token"]}
    assert create["kty"] == "EC"
    assert create["crv"] == "P-256"
    assert create["attributes"] == %{"exportable" => false}

    sign_path = "/keys/device-ca-#{account.id}/v1/sign"
    assert_received {"POST", ^sign_path, %{"alg" => "ES256"}, ["Bearer vault-token"]}
  end

  test "never sends the token outside the vault" do
    Req.Test.stub(DeviceCA.KeyVault, fn _conn -> flunk("unexpected request") end)

    assert DeviceCA.KeyVault.sign("https://other.example.test/keys/a/1", :crypto.hash(:sha256, "")) ==
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
end
