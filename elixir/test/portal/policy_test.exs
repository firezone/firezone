defmodule Portal.PolicyTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.GroupFixtures
  import Portal.ResourceFixtures
  import Portal.PolicyFixtures

  alias Portal.Policy

  defp build_changeset(attrs) do
    %Policy{}
    |> cast(attrs, [:description, :group_id, :resource_id, :account_id])
    |> Policy.changeset()
  end

  describe "changeset/1 description validation" do
    test "validates description length maximum" do
      changeset = build_changeset(%{description: String.duplicate("a", 1025)})
      assert %{description: ["should be at most 1024 character(s)"]} = errors_on(changeset)
    end

    test "allows empty description" do
      # Empty string passes validation - the min: 1 only applies to non-empty strings
      changeset = build_changeset(%{description: ""})
      refute Map.has_key?(errors_on(changeset), :description)
    end

    test "accepts valid description length" do
      changeset = build_changeset(%{description: "A valid policy description"})
      refute Map.has_key?(errors_on(changeset), :description)
    end

    test "accepts nil description" do
      changeset = build_changeset(%{description: nil})
      refute Map.has_key?(errors_on(changeset), :description)
    end

    test "accepts description at maximum length" do
      changeset = build_changeset(%{description: String.duplicate("a", 1024)})
      refute Map.has_key?(errors_on(changeset), :description)
    end
  end

  describe "changeset/1 unique constraints" do
    test "enforces unique constraint on account_id, resource_id, group_id combination" do
      account = account_fixture()
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)

      _existing_policy = policy_fixture(account: account, group: group, resource: resource)

      {:error, changeset} =
        %Policy{}
        |> cast(
          %{
            account_id: account.id,
            group_id: group.id,
            resource_id: resource.id
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()

      assert %{base: ["Policy for the selected Group and Resource already exists"]} =
               errors_on(changeset)
    end

    test "allows same group with different resources" do
      account = account_fixture()
      group = group_fixture(account: account)
      resource1 = resource_fixture(account: account)
      resource2 = resource_fixture(account: account)

      _existing_policy = policy_fixture(account: account, group: group, resource: resource1)

      {:ok, _policy} =
        %Policy{}
        |> cast(
          %{
            account_id: account.id,
            group_id: group.id,
            resource_id: resource2.id
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()
    end

    test "allows same resource with different groups" do
      account = account_fixture()
      group1 = group_fixture(account: account)
      group2 = group_fixture(account: account)
      resource = resource_fixture(account: account)

      _existing_policy = policy_fixture(account: account, group: group1, resource: resource)

      {:ok, _policy} =
        %Policy{}
        |> cast(
          %{
            account_id: account.id,
            group_id: group2.id,
            resource_id: resource.id
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()
    end
  end

  describe "changeset/1 association constraints" do
    test "enforces resource association constraint" do
      account = account_fixture()
      group = group_fixture(account: account)

      {:error, changeset} =
        %Policy{}
        |> cast(
          %{
            account_id: account.id,
            group_id: group.id,
            resource_id: Ecto.UUID.generate()
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()

      assert %{resource: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces group association constraint" do
      account = account_fixture()
      resource = resource_fixture(account: account)

      {:error, changeset} =
        %Policy{}
        |> cast(
          %{
            account_id: account.id,
            group_id: Ecto.UUID.generate(),
            resource_id: resource.id
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()

      assert %{group: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "changeset/1 cross-account constraints" do
    test "rejects group from different account via assoc constraint" do
      # When a group from a different account is used, the assoc_constraint
      # catches it first because the FK constraint fails before the unique constraint
      account1 = account_fixture()
      account2 = account_fixture()
      group = group_fixture(account: account2)
      resource = resource_fixture(account: account1)

      {:error, changeset} =
        %Policy{}
        |> cast(
          %{
            account_id: account1.id,
            group_id: group.id,
            resource_id: resource.id
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()

      assert %{group: ["does not exist"]} = errors_on(changeset)
    end

    test "rejects resource from different account via assoc constraint" do
      # When a resource from a different account is used, the assoc_constraint
      # catches it first because the FK constraint fails before the unique constraint
      account1 = account_fixture()
      account2 = account_fixture()
      group = group_fixture(account: account1)
      resource = resource_fixture(account: account2)

      {:error, changeset} =
        %Policy{}
        |> cast(
          %{
            account_id: account1.id,
            group_id: group.id,
            resource_id: resource.id
          },
          [:account_id, :group_id, :resource_id]
        )
        |> Policy.changeset()
        |> Repo.insert()

      assert %{resource: ["does not exist"]} = errors_on(changeset)
    end
  end
end
