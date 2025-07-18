defmodule Domain.Events.Hooks.FlowsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Flows
  alias Domain.Flows

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(%{})
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok == on_update(%{}, %{})
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted flow" do
      :ok = Domain.PubSub.Account.subscribe("00000000-0000-0000-0000-000000000000")

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000001",
        "account_id" => "00000000-0000-0000-0000-000000000000",
        "client_id" => "00000000-0000-0000-0000-000000000002",
        "gateway_id" => "00000000-0000-0000-0000-000000000003",
        "resource_id" => "00000000-0000-0000-0000-000000000004",
        "token_id" => "00000000-0000-0000-0000-000000000005",
        "actor_group_membership_id" => "00000000-0000-0000-0000-000000000006",
        "policy_id" => "00000000-0000-0000-0000-000000000007",
        "inserted_at" => "2023-01-01T00:00:00Z"
      }

      assert :ok == on_delete(old_data)

      assert_receive {:deleted, %Flows.Flow{} = flow}

      assert flow.id == "00000000-0000-0000-0000-000000000001"
      assert flow.account_id == "00000000-0000-0000-0000-000000000000"
      assert flow.client_id == "00000000-0000-0000-0000-000000000002"
      assert flow.gateway_id == "00000000-0000-0000-0000-000000000003"
      assert flow.resource_id == "00000000-0000-0000-0000-000000000004"
      assert flow.token_id == "00000000-0000-0000-0000-000000000005"
      assert flow.actor_group_membership_id == "00000000-0000-0000-0000-000000000006"
      assert flow.policy_id == "00000000-0000-0000-0000-000000000007"
      assert flow.inserted_at == ~U[2023-01-01 00:00:00.000000Z]
    end
  end
end
