defmodule Portal.Changes.Hooks.GatewaysTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Devices
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PG
  alias Portal.PubSub

  describe "insert/1" do
    test "broadcasts inserted gateway" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :devices)

      data = %{"id" => gateway.id, "type" => "gateway", "account_id" => account.id}

      assert :ok == on_insert(0, data)
      assert_receive %Change{op: :insert, struct: %Device{} = inserted_gateway, lsn: 0}
      assert inserted_gateway.id == gateway.id
    end
  end

  describe "update/2" do
    test "update returns :ok" do
      account = account_fixture()

      assert :ok =
               on_update(
                 0,
                 %{"id" => Ecto.UUID.generate(), "type" => "gateway", "account_id" => account.id},
                 %{"id" => Ecto.UUID.generate(), "type" => "gateway", "account_id" => account.id}
               )
    end

    test "rotated public key deletes the prior authorizations and tells the clients" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      client = client_fixture(account: account)
      PG.register(client.id)

      authorization =
        policy_authorization_fixture(account: account, client: client, gateway: gateway)

      old_data = %{
        "id" => gateway.id,
        "type" => "gateway",
        "account_id" => account.id,
        "public_key" => generate_public_key(),
        "last_seen_at" => "2026-10-01T00:00:00Z"
      }

      data =
        Map.merge(old_data, %{
          "public_key" => generate_public_key(),
          "last_seen_at" => DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()
        })

      assert :ok == on_update(0, old_data, data)

      assert_receive {:pubkey_changed, gateway_id}
      assert gateway_id == gateway.id
      refute Repo.get_by(Portal.PolicyAuthorization, id: authorization.id)
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted gateway" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)

      :ok = PubSub.Changes.subscribe(account.id, :devices)

      old_data = %{
        "id" => gateway.id,
        "type" => "gateway",
        "account_id" => account.id,
        "name" => "Test Gateway"
      }

      assert :ok = on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %Device{} = deleted_gateway,
        lsn: 0
      }

      assert deleted_gateway.id == gateway.id
    end
  end
end
