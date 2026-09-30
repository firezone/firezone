defmodule Portal.GitHub.AuthProviderTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias Portal.GitHub.AuthProvider

  @fields [:name, :context, :issuer, :is_verified]

  setup do
    %{account: account_fixture()}
  end

  defp changeset(account, attrs) do
    %AuthProvider{account_id: account.id}
    |> Ecto.Changeset.cast(attrs, @fields ++ [:portal_session_lifetime_secs, :email_verification_method])
    |> AuthProvider.changeset()
  end

  describe "changeset/1" do
    test "accepts the GitHub issuer with defaults", %{account: account} do
      changeset = changeset(account, %{issuer: "https://github.com/login/oauth", is_verified: true})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :name) == "GitHub"
      assert Ecto.Changeset.get_field(changeset, :context) == :clients_and_portal
      assert Ecto.Changeset.get_field(changeset, :email_verification_method) == :proof
    end

    test "accepts none and proof email verification", %{account: account} do
      for method <- ["none", "proof"] do
        changeset =
          changeset(account, %{
            issuer: "https://github.com/login/oauth",
            is_verified: true,
            email_verification_method: method
          })

        assert changeset.valid?
      end
    end

    # Claim is what "none" already means for GitHub, so it is not a separate option.
    test "rejects other email verification methods", %{account: account} do
      for method <- ["claim", "bogus"] do
        changeset =
          changeset(account, %{
            issuer: "https://github.com/login/oauth",
            is_verified: true,
            email_verification_method: method
          })

        assert "is invalid" in errors_on(changeset).email_verification_method
      end
    end

    test "defaults to proof in the database", %{account: account} do
      provider = github_provider_fixture(account: account)
      assert Repo.reload!(provider).email_verification_method == :proof
    end

    test "requires verification", %{account: account} do
      changeset = changeset(account, %{issuer: "https://github.com/login/oauth", is_verified: false})

      assert "must be accepted" in errors_on(changeset).is_verified
    end

    test "rejects any other issuer", %{account: account} do
      changeset = changeset(account, %{issuer: "https://accounts.google.com", is_verified: true})

      assert "is invalid" in errors_on(changeset).issuer
    end

    test "validates portal_session_lifetime_secs range", %{account: account} do
      changeset =
        changeset(account, %{
          issuer: "https://github.com/login/oauth",
          is_verified: true,
          portal_session_lifetime_secs: 299
        })

      assert "must be greater than or equal to 300" in errors_on(changeset).portal_session_lifetime_secs
    end

    test "allows only one GitHub provider per account", %{account: account} do
      github_provider_fixture(account: account)
      auth_provider = auth_provider_fixture(type: :github, account: account)

      assert {:error, changeset} =
               %AuthProvider{id: auth_provider.id}
               |> Ecto.Changeset.cast(valid_github_provider_attrs(), @fields)
               |> Ecto.Changeset.put_change(:account_id, account.id)
               |> AuthProvider.changeset()
               |> Repo.insert()

      assert "A GitHub authentication provider for this account already exists." in errors_on(
               changeset
             ).issuer
    end
  end

  test "issuer/0 returns the GitHub issuer" do
    assert AuthProvider.issuer() == "https://github.com/login/oauth"
  end
end
