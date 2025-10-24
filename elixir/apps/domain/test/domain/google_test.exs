defmodule Domain.GoogleTest do
  use Domain.DataCase, async: true
  import Domain.Google

  setup do
    account = Fixtures.Accounts.create_account()
    admin = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    unprivileged = Fixtures.Actors.create_actor(type: :account_user, account: account)
    admin_identity = Fixtures.Auth.create_identity(account: account, actor: admin)
    unprivileged_identity = Fixtures.Auth.create_identity(account: account, actor: unprivileged)

    admin_subject = Fixtures.Auth.create_subject(identity: admin_identity)
    unprivileged_subject = Fixtures.Auth.create_subject(identity: unprivileged_identity)

    %{
      account: account,
      admin: admin,
      unprivileged: unprivileged,
      admin_identity: admin_identity,
      unprivileged_identity: unprivileged_identity,
      admin_subject: admin_subject,
      unprivileged_subject: unprivileged_subject
    }
  end

  describe "create_auth_provider/2" do
    test "admin can create auth provider", %{account: account, admin_subject: subject} do
      attrs = %{hosted_domain: "example.com"}
      assert {:ok, provider} = create_auth_provider(attrs, subject)

      assert provider.account_id == account.id
      assert provider.hosted_domain == "example.com"
      assert provider.created_by == :identity
      assert provider.created_by_subject["email"] == subject.identity.email
    end

    test "unprivileged user cannot create OIDC provider", %{unprivileged_subject: subject} do
      attrs = %{hosted_domain: "example.com"}
      assert {:error, _reason} = create_oidc_provider(attrs, subject)
    end
  end

  describe "fetch_auth_provider_for_account_and_hosted_domain/2" do
    test "returns the auth provider for the account and hosted domain", %{
      account: account,
      admin_subject: subject
    } do
      attrs = %{hosted_domain: "example.com"}

      assert {:ok, provider} = create_auth_provider(attrs, subject)

      assert {:ok, ^provider} =
               fetch_auth_provider_for_account_and_hosted_domain(account, "example.com")
    end

    test "returns error if no OIDC provider exists for the account", %{account: account} do
      assert {:error, :not_found} =
               fetch_auth_provider_for_account_and_hosted_domain(account, "example.com")
    end
  end
end
