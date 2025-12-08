defmodule Domain.Changes.Hooks.PolicyAuthorizationsTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.PolicyAuthorizations
  alias Domain.{Changes.Change, PolicyAuthorization, PubSub}

  describe "insert/1" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok == on_update(0, %{}, %{})
    end
  end

  describe "delete/1" do
    test "delete broadcasts deleted policy_authorization" do
      :ok = PubSub.Account.subscribe("00000000-0000-0000-0000-000000000000")

      old_data = %{
        "id" => "00000000-0000-0000-0000-000000000001",
        "account_id" => "00000000-0000-0000-0000-000000000000",
        "client_id" => "00000000-0000-0000-0000-000000000002",
        "gateway_id" => "00000000-0000-0000-0000-000000000003",
        "resource_id" => "00000000-0000-0000-0000-000000000004",
        "token_id" => "00000000-0000-0000-0000-000000000005",
        "membership_id" => "00000000-0000-0000-0000-000000000006",
        "policy_id" => "00000000-0000-0000-0000-000000000007",
        "inserted_at" => "2023-01-01T00:00:00Z"
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{
        op: :delete,
        old_struct: %PolicyAuthorization{} = policy_authorization,
        lsn: 0
      }

      assert policy_authorization.id == "00000000-0000-0000-0000-000000000001"
      assert policy_authorization.account_id == "00000000-0000-0000-0000-000000000000"
      assert policy_authorization.client_id == "00000000-0000-0000-0000-000000000002"
      assert policy_authorization.gateway_id == "00000000-0000-0000-0000-000000000003"
      assert policy_authorization.resource_id == "00000000-0000-0000-0000-000000000004"
      assert policy_authorization.token_id == "00000000-0000-0000-0000-000000000005"
      assert policy_authorization.membership_id == "00000000-0000-0000-0000-000000000006"
      assert policy_authorization.policy_id == "00000000-0000-0000-0000-000000000007"
      assert policy_authorization.inserted_at == ~U[2023-01-01 00:00:00.000000Z]
    end
  end
end
