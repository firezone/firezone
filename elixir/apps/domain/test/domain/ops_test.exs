defmodule Domain.OpsTest do
  use Domain.DataCase, async: true
  import Domain.Ops

  describe "provision_account/1" do
    setup do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    end

    test "provisions an account when valid input is provider" do
      params = %{
        account_name: "Test Account",
        account_slug: "test_account",
        account_admin_name: "Test Admin",
        account_admin_email: "test_admin@firezone.local"
      }

      assert {:ok, _} = provision_account(params)
      assert {:ok, _} = Domain.Accounts.fetch_account_by_id_or_slug("test_account")
    end

    test "returns an error when invalid input is provided" do
      params = %{
        account_name: "Test Account",
        account_slug: "test_account",
        account_admin_name: "Test Admin",
        account_admin_email: "invalid"
      }

      # provision_account/1 catches the invalid params and raises MatchError
      assert_raise(MatchError, fn -> provision_account(params) end)
    end
  end
end
