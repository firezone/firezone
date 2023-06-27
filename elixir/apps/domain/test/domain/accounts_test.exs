defmodule Domain.AccountsTest do
  use Domain.DataCase, async: true
  import Domain.Accounts
  alias Domain.{AccountsFixtures, AuthFixtures}

  describe "fetch_account_by_id/1" do
    test "returns error when account is not found" do
      assert fetch_account_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert fetch_account_by_id("foo") == {:error, :not_found}
    end

    test "returns account" do
      account = AccountsFixtures.create_account()
      assert {:ok, returned_account} = fetch_account_by_id(account.id)
      assert returned_account.id == account.id
    end
  end

  describe "ensure_has_access_to/2" do
    test "returns :ok if subject has access to the account" do
      subject = AuthFixtures.create_subject()

      assert ensure_has_access_to(subject, subject.account) == :ok
    end

    test "returns :error if subject has no access to the account" do
      account = AccountsFixtures.create_account()
      subject = AuthFixtures.create_subject()

      assert ensure_has_access_to(subject, account) == {:error, :unauthorized}
    end
  end
end
