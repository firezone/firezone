defmodule Portal.Google.DirectoryTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures

  alias Portal.Google.Directory

  describe "changeset/1" do
    setup do
      account = account_fixture()

      %{account: account}
    end

    test "validates required fields", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(%{}, [:name, :domain, :impersonation_email, :is_verified])
        |> Directory.changeset()

      refute changeset.valid?
      # name has a default of "Google", so it won't be blank
      # domain is required
      assert "can't be blank" in errors_on(changeset).domain
      # impersonation_email is required
      assert "can't be blank" in errors_on(changeset).impersonation_email
      # is_verified has a default of false, so it won't be blank
    end

    test "validates domain length constraints", %{account: account} do
      # Test empty string shows can't be blank (not length error)
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            domain: "",
            impersonation_email: "admin@example.com",
            is_verified: true
          },
          [:name, :domain, :impersonation_email, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).domain

      # Test maximum length (> 255)
      long_domain = String.duplicate("a", 256)

      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            domain: long_domain,
            impersonation_email: "admin@example.com",
            is_verified: true
          },
          [:name, :domain, :impersonation_email, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).domain
    end

    test "validates name length constraints", %{account: account} do
      # Test maximum length (> 255)
      long_name = String.duplicate("a", 256)

      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: long_name,
            domain: "example.com",
            impersonation_email: "admin@example.com",
            is_verified: true
          },
          [:name, :domain, :impersonation_email, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).name
    end

    test "inserts domain at maximum length", %{account: account} do
      dir = google_directory_fixture(account: account, domain: String.duplicate("a", 255))
      assert String.length(dir.domain) == 255
    end

    test "inserts name at maximum length", %{account: account} do
      dir = google_directory_fixture(account: account, name: String.duplicate("a", 255))
      assert String.length(dir.name) == 255
    end

    test "validates impersonation_email format", %{account: account} do
      # Test invalid email format
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            domain: "example.com",
            impersonation_email: "not-an-email",
            is_verified: true
          },
          [:name, :domain, :impersonation_email, :is_verified]
        )
        |> Directory.changeset()

      refute changeset.valid?
      assert "is an invalid email address" in errors_on(changeset).impersonation_email
    end

    test "validates error_email_count is non-negative", %{account: account} do
      changeset =
        %Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Directory",
            domain: "example.com",
            impersonation_email: "admin@example.com",
            is_verified: true,
            error_email_count: -1
          },
          [:name, :domain, :impersonation_email, :is_verified, :error_email_count]
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
            domain: "example.com",
            impersonation_email: "admin@example.com",
            is_verified: true
          },
          [:name, :domain, :impersonation_email, :is_verified]
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
            domain: "example.com",
            impersonation_email: "admin@example.com",
            is_verified: true,
            synced_at: now,
            errored_at: now,
            is_disabled: false,
            disabled_reason: nil,
            error_message: "Test error",
            error_email_count: 2
          },
          [
            :name,
            :domain,
            :impersonation_email,
            :is_verified,
            :synced_at,
            :errored_at,
            :is_disabled,
            :disabled_reason,
            :error_message,
            :error_email_count
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
            domain: "example.com",
            impersonation_email: "admin@example.com"
          },
          [:domain, :impersonation_email]
        )
        |> Directory.changeset()

      # Default values from schema
      assert Ecto.Changeset.get_field(changeset, :name) == "Google"
      assert Ecto.Changeset.get_field(changeset, :is_disabled) == false
      assert Ecto.Changeset.get_field(changeset, :error_email_count) == 0
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
            domain: "example.com",
            impersonation_email: "admin@example.com",
            is_verified: true,
            synced_at: synced_at,
            errored_at: errored_at,
            error_message: "Sync failed",
            error_email_count: 3
          },
          [
            :name,
            :domain,
            :impersonation_email,
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
            domain: "example.com",
            impersonation_email: "admin@example.com",
            is_verified: true,
            is_disabled: true,
            disabled_reason: "Too many errors"
          },
          [:name, :domain, :impersonation_email, :is_verified, :is_disabled, :disabled_reason]
        )
        |> Directory.changeset()

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :is_disabled) == true
      assert Ecto.Changeset.get_field(changeset, :disabled_reason) == "Too many errors"
    end

    test "accepts valid email formats for impersonation_email", %{account: account} do
      valid_emails = [
        "admin@example.com",
        "user.name@example.co.uk",
        "test+tag@example.org"
      ]

      for email <- valid_emails do
        changeset =
          %Directory{account_id: account.id}
          |> Ecto.Changeset.cast(
            %{
              name: "Test Directory",
              domain: "example.com",
              impersonation_email: email,
              is_verified: true
            },
            [:name, :domain, :impersonation_email, :is_verified]
          )
          |> Directory.changeset()

        assert changeset.valid?, "Expected email #{email} to be valid"
      end
    end

    test "rejects invalid email formats for impersonation_email", %{account: account} do
      invalid_emails = [
        "not-an-email",
        "@example.com",
        "user@",
        "user name@example.com"
      ]

      for email <- invalid_emails do
        changeset =
          %Directory{account_id: account.id}
          |> Ecto.Changeset.cast(
            %{
              name: "Test Directory",
              domain: "example.com",
              impersonation_email: email,
              is_verified: true
            },
            [:name, :domain, :impersonation_email, :is_verified]
          )
          |> Directory.changeset()

        refute changeset.valid?, "Expected email #{email} to be invalid"
        assert "is an invalid email address" in errors_on(changeset).impersonation_email
      end
    end
  end
end
