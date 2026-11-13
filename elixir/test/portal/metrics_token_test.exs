defmodule Portal.MetricsTokenTest do
  use ExUnit.Case, async: true

  alias Portal.{Account, Device, MetricsToken}

  @public_key """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEA/eIbkMncRXjhDPA1HDuxjHHgj2+9qnI6fKfLzCCI++w=
  -----END PUBLIC KEY-----
  """

  @account %Account{id: "00000000-0000-0000-0000-000000000001", slug: "acme"}

  test "mints an EdDSA token that verifies against the public key" do
    device = %Device{
      id: "00000000-0000-0000-0000-000000000002",
      type: :client,
      last_seen_version: "1.5.2"
    }

    token = MetricsToken.mint(@account, device, ["a", "b"])

    assert {true, %JOSE.JWT{fields: claims}, _jws} =
             @public_key |> JOSE.JWK.from_pem() |> JOSE.JWT.verify_strict(["EdDSA"], token)

    assert %{
             "account_id" => "00000000-0000-0000-0000-000000000001",
             "account_slug" => "acme",
             "device_id" => "00000000-0000-0000-0000-000000000002",
             "device_type" => "client",
             "device_version" => "1.5.2",
             "metrics" => ["a", "b"],
             "iat" => iat,
             "exp" => exp
           } = claims

    assert exp - iat == 3600
  end

  test "omits an unknown device version" do
    device = %Device{id: "00000000-0000-0000-0000-000000000003", type: :gateway}

    token = MetricsToken.mint(@account, device, ["*"])

    assert {true, %JOSE.JWT{fields: claims}, _jws} =
             @public_key |> JOSE.JWK.from_pem() |> JOSE.JWT.verify_strict(["EdDSA"], token)

    assert claims["device_type"] == "gateway"
    refute Map.has_key?(claims, "device_version")
  end
end
