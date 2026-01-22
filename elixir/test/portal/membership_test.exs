defmodule Portal.MembershipTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures

  alias Portal.Membership

  describe "changeset/1 association constraints" do
    test "enforces account association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      group = group_fixture(account: account)

      {:error, changeset} =
        %Membership{}
        |> cast(
          %{
            account_id: Ecto.UUID.generate(),
            actor_id: actor.id,
            group_id: group.id
          },
          [:account_id, :actor_id, :group_id]
        )
        |> Membership.changeset()
        |> Repo.insert()

      assert %{account: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces actor association constraint" do
      account = account_fixture()
      group = group_fixture(account: account)

      {:error, changeset} =
        %Membership{}
        |> cast(
          %{
            actor_id: Ecto.UUID.generate(),
            group_id: group.id
          },
          [:actor_id, :group_id]
        )
        |> put_assoc(:account, account)
        |> Membership.changeset()
        |> Repo.insert()

      assert %{actor: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces group association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:error, changeset} =
        %Membership{}
        |> cast(
          %{
            actor_id: actor.id,
            group_id: Ecto.UUID.generate()
          },
          [:actor_id, :group_id]
        )
        |> put_assoc(:account, account)
        |> Membership.changeset()
        |> Repo.insert()

      assert %{group: ["does not exist"]} = errors_on(changeset)
    end

    test "allows valid associations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      group = group_fixture(account: account)

      {:ok, membership} =
        %Membership{}
        |> cast(
          %{
            actor_id: actor.id,
            group_id: group.id
          },
          [:actor_id, :group_id]
        )
        |> put_assoc(:account, account)
        |> Membership.changeset()
        |> Repo.insert()

      assert membership.account_id == account.id
      assert membership.actor_id == actor.id
      assert membership.group_id == group.id
    end
  end
end
