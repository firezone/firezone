defmodule Portal.SiteTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures

  alias Portal.Site

  defp build_changeset(attrs) do
    %Site{}
    |> cast(attrs, [:name, :managed_by, :account_id])
    |> Site.changeset()
  end

  describe "changeset/1 basic validations" do
    test "validates name is required" do
      changeset = build_changeset(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name length minimum" do
      changeset = build_changeset(%{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name length maximum" do
      changeset = build_changeset(%{name: String.duplicate("a", 65)})
      assert %{name: ["should be at most 64 character(s)"]} = errors_on(changeset)
    end

    test "accepts valid name length" do
      changeset = build_changeset(%{name: "Valid Site Name"})
      refute Map.has_key?(errors_on(changeset), :name)
    end

    test "accepts name at maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 64)})
      refute Map.has_key?(errors_on(changeset), :name)
    end
  end

  describe "changeset/1 association constraints" do
    test "enforces account association constraint" do
      {:error, changeset} =
        %Site{}
        |> cast(
          %{
            account_id: Ecto.UUID.generate(),
            name: "Test Site"
          },
          [:account_id, :name]
        )
        |> Site.changeset()
        |> Repo.insert()

      assert %{account: ["does not exist"]} = errors_on(changeset)
    end

    test "allows valid account association" do
      account = account_fixture()

      {:ok, site} =
        %Site{}
        |> cast(%{name: "Test Site"}, [:name])
        |> put_assoc(:account, account)
        |> Site.changeset()
        |> Repo.insert()

      assert site.account_id == account.id
    end
  end

  describe "changeset/1 unique constraints" do
    test "enforces unique constraint on account_id and name with managed_by" do
      account = account_fixture()

      {:ok, _site} =
        %Site{}
        |> cast(%{name: "Test Site", managed_by: :account}, [:name, :managed_by])
        |> put_assoc(:account, account)
        |> Site.changeset()
        |> Repo.insert()

      {:error, changeset} =
        %Site{}
        |> cast(%{name: "Test Site", managed_by: :account}, [:name, :managed_by])
        |> put_assoc(:account, account)
        |> Site.changeset()
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
