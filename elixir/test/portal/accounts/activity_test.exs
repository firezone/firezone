defmodule Portal.Accounts.ActivityTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SessionLogFixtures

  alias Portal.Accounts.Activity

  describe "account_active?/1" do
    test "returns true for an account with a session log" do
      account = account_fixture()
      session_log_fixture(account: account)

      assert Activity.account_active?(account.id)
    end

    test "returns false for an account with no session logs" do
      account = account_fixture()

      refute Activity.account_active?(account.id)
    end

    test "counts gateway sessions, not just sign-ins" do
      account = account_fixture()
      session_log_fixture(account: account, context: :gateway)

      assert Activity.account_active?(account.id)
    end

    test "ignores session logs belonging to another account" do
      account = account_fixture()
      session_log_fixture(account: account_fixture())

      refute Activity.account_active?(account.id)
    end

    test "returns false for an account that does not exist" do
      refute Activity.account_active?(Ecto.UUID.generate())
    end
  end

  describe "active_account_ids/1" do
    test "returns only the active ids" do
      active = account_fixture()
      dormant = account_fixture()
      session_log_fixture(account: active)

      assert Activity.active_account_ids([active.id, dormant.id]) ==
               MapSet.new([active.id])
    end

    test "returns an empty set for an empty list" do
      assert Activity.active_account_ids([]) == MapSet.new()
    end

    test "does not repeat an account with many session logs" do
      account = account_fixture()
      session_log_fixture(account: account)
      session_log_fixture(account: account)

      assert Activity.active_account_ids([account.id]) == MapSet.new([account.id])
    end
  end
end
