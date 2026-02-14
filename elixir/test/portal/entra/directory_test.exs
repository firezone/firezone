defmodule Portal.Entra.DirectoryTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.Entra.Directory

  describe "changeset/1" do
    setup do
      account = account_fixture()

      %{account: account}
    end

    test "validates required fields", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(%{}, [:name, :tenant_id, :is_verified])
        |> Directory.changeset()

      refute changeset.valid?
      # name has a default of "Entra", so it won't be blank
      # tenant_id is required
      assert "can't be blank" in errors_on(changeset).tenant_id
      # is_verified also has a default of true, so it won't be blank
    end

    test "validates tenant_id length constraints", %{account: account} do
      # Test empty string shows can't be blank (not length error)
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "",
            is_verified: true
          },
          [:name, :tenant_id, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).tenant_id

      # Test maximum length (> 255)
      long_tenant_id = String.duplicate("a", 256)

      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: long_tenant_id,
            is_verified: true
          },
          [:name, :tenant_id, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).tenant_id
    end

    test "validates name length constraints", %{account: account} do
      # Test maximum length (> 255)
      # Note: Empty name gets default "Entra" value, so we test max length only
      long_name = String.duplicate("a", 256)

      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: long_name,
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true
          },
          [:name, :tenant_id, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).name
    end

    test "inserts tenant_id at maximum length", %{account: account} do
      dir = entra_directory_fixture(account: account, tenant_id: String.duplicate("a", 255))
      assert String.length(dir.tenant_id) == 255
    end

    test "inserts name at maximum length", %{account: account} do
      dir = entra_directory_fixture(account: account, name: String.duplicate("a", 255))
      assert String.length(dir.name) == 255
    end

    test "validates error_email_count is non-negative", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true,
            error_email_count: -1
          },
          [:name, :tenant_id, :is_verified, :error_email_count]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).error_email_count
    end

    test "accepts valid changeset with required fields", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true
          },
          [:name, :tenant_id, :is_verified]
        )
        |> Directory.changeset()

      assert changeset.valid?
    end

    test "accepts valid changeset with all optional fields", %{account: account} do
      now = DateTime.utc_now()

      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true,
            synced_at: now,
            errored_at: now,
            is_disabled: false,
            disabled_reason: nil,
            error_message: "Test error",
            error_email_count: 2,
            sync_all_groups: true
          },
          [
            :name,
            :tenant_id,
            :is_verified,
            :synced_at,
            :errored_at,
            :is_disabled,
            :disabled_reason,
            :error_message,
            :error_email_count,
            :sync_all_groups
          ]
        )
        |> Directory.changeset()

      assert changeset.valid?
    end

    test "sets default values", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            tenant_id: "12345678-1234-1234-1234-123456789012"
          },
          [:tenant_id]
        )
        |> Directory.changeset()

      # Default values from schema
      assert Ecto.Changeset.get_field(changeset, :name) == "Entra"
      assert Ecto.Changeset.get_field(changeset, :is_disabled) == false
      assert Ecto.Changeset.get_field(changeset, :error_email_count) == 0
      assert Ecto.Changeset.get_field(changeset, :sync_all_groups) == false
      assert Ecto.Changeset.get_field(changeset, :is_verified) == false
    end

    test "allows synced and errored timestamps to be set", %{account: account} do
      synced_at = DateTime.utc_now() |> DateTime.add(-3600, :second)
      errored_at = DateTime.utc_now()

      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true,
            synced_at: synced_at,
            errored_at: errored_at,
            error_message: "Sync failed",
            error_email_count: 3
          },
          [
            :name,
            :tenant_id,
            :is_verified,
            :synced_at,
            :errored_at,
            :error_message,
            :error_email_count
          ]
        )
        |> Directory.changeset()

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :synced_at) == synced_at
      assert Ecto.Changeset.get_field(changeset, :errored_at) == errored_at
      assert Ecto.Changeset.get_field(changeset, :error_message) == "Sync failed"
      assert Ecto.Changeset.get_field(changeset, :error_email_count) == 3
    end

    test "allows disabled state to be set", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true,
            is_disabled: true,
            disabled_reason: "Too many errors"
          },
          [:name, :tenant_id, :is_verified, :is_disabled, :disabled_reason]
        )
        |> Directory.changeset()

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :is_disabled) == true
      assert Ecto.Changeset.get_field(changeset, :disabled_reason) == "Too many errors"
    end

    test "allows sync_all_groups flag to be set", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            tenant_id: "12345678-1234-1234-1234-123456789012",
            is_verified: true,
            sync_all_groups: true
          },
          [:name, :tenant_id, :is_verified, :sync_all_groups]
        )
        |> Directory.changeset()

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :sync_all_groups) == true
    end
  end
end
