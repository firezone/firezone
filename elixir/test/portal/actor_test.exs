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

    test "rejects email host without a dot" do
      changeset =
        build_changeset(%{
          name: "Test Actor",
          type: :account_user,
          email: "user@localhost"
        })

      assert %{email: ["is an invalid email address"]} = errors_on(changeset)
    end
  end

  describe "changeset/1 type transitions" do
    test "allows setting type on a new actor" do
      changeset =
        %Actor{}
        |> cast(%{name: "Alice", type: :account_user}, [:name, :type])
        |> Actor.changeset()

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :type)
    end

    test "allows account_user to account_admin_user transition" do
      changeset =
        %Actor{type: :account_user, name: "Alice"}
        |> cast(%{type: :account_admin_user}, [:type])
        |> Actor.changeset()

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :type)
    end

    test "allows account_admin_user to account_user transition" do
      changeset =
        %Actor{type: :account_admin_user, name: "Alice"}
        |> cast(%{type: :account_user}, [:type])
        |> Actor.changeset()

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :type)
    end

    test "rejects account_user to service_account transition" do
      changeset =
        %Actor{type: :account_user, name: "Alice"}
        |> cast(%{type: :service_account}, [:type])
        |> Actor.changeset()

      assert %{type: ["cannot change a user to a service account or API client"]} =
               errors_on(changeset)
    end

    test "rejects account_user to api_client transition" do
      changeset =
        %Actor{type: :account_user, name: "Alice"}
        |> cast(%{type: :api_client}, [:type])
        |> Actor.changeset()

      assert %{type: ["cannot change a user to a service account or API client"]} =
               errors_on(changeset)
    end

    test "rejects account_admin_user to service_account transition" do
      changeset =
        %Actor{type: :account_admin_user, name: "Alice"}
        |> cast(%{type: :service_account}, [:type])
        |> Actor.changeset()

      assert %{type: ["cannot change a user to a service account or API client"]} =
               errors_on(changeset)
    end

    test "rejects account_admin_user to api_client transition" do
      changeset =
        %Actor{type: :account_admin_user, name: "Alice"}
        |> cast(%{type: :api_client}, [:type])
        |> Actor.changeset()

      assert %{type: ["cannot change a user to a service account or API client"]} =
               errors_on(changeset)
    end

    test "rejects api_client to any other type" do
      for new_type <- [:account_user, :account_admin_user, :service_account] do
        changeset =
          %Actor{type: :api_client, name: "Bot"}
          |> cast(%{type: new_type}, [:type])
          |> Actor.changeset()

        assert %{type: ["cannot change the type of an API client"]} = errors_on(changeset)
      end
    end

    test "rejects service_account to any other type" do
      for new_type <- [:account_user, :account_admin_user, :api_client] do
        changeset =
          %Actor{type: :service_account, name: "Svc"}
          |> cast(%{type: new_type}, [:type])
          |> Actor.changeset()

        assert %{type: ["cannot change the type of a service account"]} = errors_on(changeset)
      end
    end

    test "allows no-op when type field is set but unchanged" do
      changeset =
        %Actor{type: :api_client, name: "Bot"}
        |> cast(%{type: :api_client}, [:type])
        |> Actor.changeset()

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :type)
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

  describe "email_meaningfully_changed?/1" do
    test "returns false when email is absent from attrs" do
      changeset = cast(%Actor{email: "user@example.com"}, %{name: "x"}, [:name, :email])
      refute Actor.email_meaningfully_changed?(changeset)
    end

    test "returns false when email is identical" do
      changeset =
        cast(%Actor{email: "user@example.com"}, %{email: "user@example.com"}, [:email])

      refute Actor.email_meaningfully_changed?(changeset)
    end

    test "returns false when only whitespace differs" do
      changeset =
        cast(%Actor{email: "user@example.com"}, %{email: "  user@example.com  "}, [:email])

      refute Actor.email_meaningfully_changed?(changeset)
    end

    test "returns true when email value differs after trim" do
      changeset =
        cast(%Actor{email: "user@example.com"}, %{email: "other@example.com"}, [:email])

      assert Actor.email_meaningfully_changed?(changeset)
    end

    test "returns true when email is being cleared" do
      changeset = cast(%Actor{email: "user@example.com"}, %{email: ""}, [:email])
      assert Actor.email_meaningfully_changed?(changeset)
    end

    test "returns true when email is being assigned to a previously nil actor" do
      changeset = cast(%Actor{email: nil}, %{email: "new@example.com"}, [:email])
      assert Actor.email_meaningfully_changed?(changeset)
    end
  end
end
