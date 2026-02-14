defmodule Portal.AccountTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures

  alias Portal.Account

  defp build_changeset(attrs) do
    %Account{}
    |> cast(attrs, [:name, :slug, :legal_name])
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
end
