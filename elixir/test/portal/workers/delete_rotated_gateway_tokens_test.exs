defmodule Portal.Workers.DeleteRotatedGatewayTokensTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.DeviceFixtures
  import Portal.TokenFixtures

  alias Portal.GatewayToken
  alias Portal.Workers.DeleteRotatedGatewayTokens

  describe "perform/1" do
    test "deletes rotated tokens past the grace period" do
      gateway = gateway_fixture()
      grace_hours = GatewayToken.rotation_grace_hours()
      rotated_at = DateTime.add(DateTime.utc_now(), -(grace_hours + 1), :hour)
      token = gateway_token_fixture(gateway: gateway, rotated_at: rotated_at)

      assert :ok = perform_job(DeleteRotatedGatewayTokens, %{})

      refute Repo.get_by(GatewayToken, account_id: token.account_id, id: token.id)
    end

    test "keeps rotated tokens within the grace period" do
      gateway = gateway_fixture()
      token = gateway_token_fixture(gateway: gateway, rotated_at: DateTime.utc_now())

      assert :ok = perform_job(DeleteRotatedGatewayTokens, %{})

      assert Repo.get_by(GatewayToken, account_id: token.account_id, id: token.id)
    end

    test "keeps active tokens" do
      gateway = gateway_fixture()
      token = gateway_token_fixture(gateway: gateway)

      assert :ok = perform_job(DeleteRotatedGatewayTokens, %{})

      assert Repo.get_by(GatewayToken, account_id: token.account_id, id: token.id)
    end

    test "keeps multi-owner site tokens" do
      token = gateway_token_fixture()

      assert :ok = perform_job(DeleteRotatedGatewayTokens, %{})

      assert Repo.get_by(GatewayToken, account_id: token.account_id, id: token.id)
    end

    test "deletes expired rotated tokens across accounts" do
      grace_hours = GatewayToken.rotation_grace_hours()
      rotated_at = DateTime.add(DateTime.utc_now(), -(grace_hours + 1), :hour)

      tokens =
        for _ <- 1..2 do
          gateway_token_fixture(gateway: gateway_fixture(), rotated_at: rotated_at)
        end

      assert :ok = perform_job(DeleteRotatedGatewayTokens, %{})

      for token <- tokens do
        refute Repo.get_by(GatewayToken, account_id: token.account_id, id: token.id)
      end
    end
  end
end
