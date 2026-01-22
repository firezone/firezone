defmodule Portal.OneTimePasscodeTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.OneTimePasscode

  describe "changeset/1 association constraints" do
    test "enforces actor association constraint" do
      account = account_fixture()

      {:error, changeset} =
        %OneTimePasscode{}
        |> cast(
          %{
            actor_id: Ecto.UUID.generate(),
            code_hash: "some_hash",
            expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
          },
          [:actor_id, :code_hash, :expires_at]
        )
        |> put_assoc(:account, account)
        |> OneTimePasscode.changeset()
        |> Repo.insert()

      assert %{actor: ["does not exist"]} = errors_on(changeset)
    end

    test "allows valid associations" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, otp} =
        %OneTimePasscode{}
        |> cast(
          %{
            code_hash: "some_hash",
            expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
          },
          [:code_hash, :expires_at]
        )
        |> put_assoc(:account, account)
        |> put_assoc(:actor, actor)
        |> OneTimePasscode.changeset()
        |> Repo.insert()

      assert otp.account_id == account.id
      assert otp.actor_id == actor.id
    end
  end
end
