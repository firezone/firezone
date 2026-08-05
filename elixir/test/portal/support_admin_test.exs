defmodule Portal.SupportAdminTest do
  use Portal.DataCase, async: true

  import Portal.SupportAdminFixtures

  alias Portal.Safe
  alias Portal.SupportAdmin

  defp insert_admin(attrs) do
    %SupportAdmin{}
    |> Ecto.Changeset.cast(attrs, [:email])
    |> Safe.unscoped()
    |> Safe.insert()
  end

  describe "changeset/1" do
    test "rejects non-firezone.dev emails" do
      assert {:error, changeset} = insert_admin(%{email: "someone@gmail.com"})
      assert "must be a firezone.dev email" in errors_on(changeset).email
    end

    test "rejects lookalike domains" do
      assert {:error, changeset} = insert_admin(%{email: "someone@fake-firezone.dev.evil.com"})
      assert "must be a firezone.dev email" in errors_on(changeset).email
    end

    test "requires email" do
      assert {:error, changeset} = insert_admin(%{})
      assert "can't be blank" in errors_on(changeset).email
    end

    test "downcases and trims the email" do
      assert {:ok, support_admin} = insert_admin(%{email: "  Thomas@Firezone.DEV  "})
      assert support_admin.email == "thomas@firezone.dev"
    end

    test "enforces case-insensitive uniqueness" do
      support_admin_fixture(email: "unique@firezone.dev")
      assert {:error, changeset} = insert_admin(%{email: "UNIQUE@firezone.dev"})
      assert "has already been taken" in errors_on(changeset).email
    end
  end
end
