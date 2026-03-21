defmodule Portal.AccountTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures

  alias Portal.Account

  alias Portal.Repo

  defp build_changeset(attrs) do
    %Account{}
    |> cast(attrs, [:name, :slug, :legal_name, :key])
    |> Account.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      account = account_fixture(name: String.duplicate("a", 64))
      assert String.length(account.name) == 64
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 65)})
      assert %{name: ["should be at most 64 character(s)"]} = errors_on(changeset)
    end

    test "inserts slug at maximum length" do
      account = account_fixture(slug: String.duplicate("a", 100))
      assert String.length(account.slug) == 100
    end

    test "rejects slug exceeding maximum length" do
      changeset = build_changeset(%{slug: String.duplicate("a", 101)})
      assert %{slug: ["should be at most 100 character(s)"]} = errors_on(changeset)
    end

    test "inserts legal_name at maximum length" do
      account = account_fixture(legal_name: String.duplicate("a", 255))
      assert String.length(account.legal_name) == 255
    end

    test "rejects legal_name exceeding maximum length" do
      changeset = build_changeset(%{legal_name: String.duplicate("a", 256)})
      assert %{legal_name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end

  describe "new_key/0" do
    test "returns a 6-character base-36 string" do
      key = Account.new_key()
      assert String.length(key) == 6
      assert key =~ ~r/^[a-z0-9]{6}$/
    end

    test "returns different values on successive calls" do
      keys = for _ <- 1..10, do: Account.new_key()
      assert length(Enum.uniq(keys)) > 1
    end
  end

  describe "changeset/1 key validations" do
    test "rejects key with wrong length" do
      changeset = build_changeset(%{key: "abc"})
      assert %{key: ["should be 6 character(s)"]} = errors_on(changeset)
    end

    test "enforces unique constraint on key" do
      account = account_fixture()

      {:error, changeset} =
        %Account{}
        |> cast(valid_account_attrs(%{key: account.key}), [:name, :slug, :legal_name, :key])
        |> Account.changeset()
        |> Repo.insert()

      assert %{key: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
