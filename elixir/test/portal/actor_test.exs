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

    test "returns false when only case differs" do
      changeset =
        cast(%Actor{email: "user@example.com"}, %{email: "User@Example.COM"}, [:email])

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

  describe "support email helpers" do
    test "support_email/1 tags the local part" do
      assert Actor.support_email("thomas@firezone.dev") ==
               "thomas+firezone-support@firezone.dev"
    end

    test "support_email/1 handles emails that already carry a plus tag" do
      assert Actor.support_email("thomas+x@firezone.dev") ==
               "thomas+x+firezone-support@firezone.dev"
    end

    test "support?/1 matches actors by type and emails by suffix" do
      assert Actor.support?(%Actor{type: :firezone_support})
      refute Actor.support?(%Actor{type: :account_admin_user})
      assert Actor.support?("thomas+firezone-support@firezone.dev")
      assert Actor.support?("Thomas+Firezone-Support@Firezone.DEV")
      refute Actor.support?("thomas@firezone.dev")
      refute Actor.support?(nil)
    end
  end

  describe "changeset/1 firezone_support type protection" do
    test "rejects creating an actor with the firezone_support type" do
      changeset =
        build_changeset(%{
          name: "Sneaky",
          type: :firezone_support,
          email: "someone@example.com"
        })

      assert "is reserved" in errors_on(changeset).type
    end

    test "rejects transitioning an actor to firezone_support" do
      changeset =
        %Actor{type: :account_admin_user, name: "Alice"}
        |> cast(%{type: :firezone_support}, [:type])
        |> Actor.changeset()

      assert "is reserved" in errors_on(changeset).type
    end

    test "rejects any modification of a firezone_support actor" do
      changeset =
        %Actor{type: :firezone_support, name: "Firezone Support"}
        |> cast(%{name: "Renamed"}, [:name])
        |> Actor.changeset()

      assert "Firezone Support actors cannot be modified" in errors_on(changeset).type
    end

    test "database rejects firezone_support actors without the reserved email" do
      account = account_fixture()

      assert_raise Ecto.ConstraintError, ~r/type_is_valid/, fn ->
        %Actor{
          account_id: account.id,
          type: :firezone_support,
          name: "Firezone Support",
          email: "untagged@firezone.dev"
        }
        |> Portal.Repo.insert!()
      end
    end
  end

  describe "changeset/1 reserved support suffix" do
    test "rejects creating an actor with the reserved suffix" do
      changeset =
        build_changeset(%{
          name: "Sneaky",
          type: :account_user,
          email: "someone+firezone-support@firezone.dev"
        })

      assert "is reserved" in errors_on(changeset).email
    end

    test "rejects updating an actor email into the reserved suffix" do
      actor = actor_fixture(type: :account_user)

      changeset =
        actor
        |> cast(%{email: "someone+firezone-support@firezone.dev"}, [:email])
        |> Actor.changeset()

      assert "is reserved" in errors_on(changeset).email
    end

    test "allows regular firezone.dev emails" do
      changeset =
        build_changeset(%{
          name: "Staff",
          type: :account_user,
          email: "someone@firezone.dev"
        })

      refute errors_on(changeset)[:email]
    end
  end
end
