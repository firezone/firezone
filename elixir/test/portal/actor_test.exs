defmodule Portal.ActorTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DirectoryFixtures

  alias Portal.Actor

  defp build_changeset(attrs) do
    %Actor{}
    |> cast(attrs, [:name, :type, :email])
    |> Actor.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      actor = actor_fixture(name: String.duplicate("a", 255))
      assert String.length(actor.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end

  describe "changeset/1 association constraints" do
    test "enforces account association constraint" do
      {:error, changeset} =
        %Actor{}
        |> cast(
          %{
            account_id: Ecto.UUID.generate(),
            name: "Test Actor",
            type: :account_user,
            email: "test@example.com"
          },
          [:account_id, :name, :type, :email]
        )
        |> Actor.changeset()
        |> Repo.insert()

      assert %{account: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces directory association constraint" do
      account = account_fixture()

      {:error, changeset} =
        %Actor{}
        |> cast(
          %{
            account_id: account.id,
            name: "Test Actor",
            type: :account_user,
            email: "test@example.com",
            created_by_directory_id: Ecto.UUID.generate()
          },
          [:account_id, :name, :type, :email, :created_by_directory_id]
        )
        |> Actor.changeset()
        |> Repo.insert()

      assert %{directory: ["does not exist"]} = errors_on(changeset)
    end

    test "allows nil directory" do
      account = account_fixture()

      {:ok, actor} =
        %Actor{}
        |> cast(
          %{
            name: "Test Actor",
            type: :account_user,
            email: "test@example.com"
          },
          [:name, :type, :email]
        )
        |> put_assoc(:account, account)
        |> Actor.changeset()
        |> Repo.insert()

      assert actor.created_by_directory_id == nil
    end

    test "allows valid directory association" do
      account = account_fixture()
      directory = directory_fixture(account: account)

      {:ok, actor} =
        %Actor{}
        |> cast(
          %{
            name: "Test Actor",
            type: :account_user,
            email: "test@example.com",
            created_by_directory_id: directory.id
          },
          [:name, :type, :email, :created_by_directory_id]
        )
        |> put_assoc(:account, account)
        |> Actor.changeset()
        |> Repo.insert()

      assert actor.created_by_directory_id == directory.id
    end
  end
end
