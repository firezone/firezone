defmodule Domain.Auth.Adapters.EmailTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.Email
  alias Domain.Auth
  alias Domain.{AccountsFixtures, AuthFixtures}

  describe "identity_changeset/2" do
    setup do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      changeset = %Auth.Identity{} |> Ecto.Changeset.change()

      %{
        account: account,
        provider: provider,
        changeset: changeset
      }
    end

    test "puts default provider state", %{provider: provider, changeset: changeset} do
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)

      assert %{
               provider_state: %{
                 "sign_in_token_created_at" => %DateTime{},
                 "sign_in_token_hash" => sign_in_token_hash
               },
               provider_virtual_state: %{sign_in_token: sign_in_token}
             } = changeset.changes

      assert Domain.Crypto.equal?(sign_in_token, sign_in_token_hash)
    end

    test "trims provider identifier", %{provider: provider, changeset: changeset} do
      changeset = Ecto.Changeset.put_change(changeset, :provider_identifier, " X ")
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert changeset.changes.provider_identifier == "X"
    end
  end

  describe "provider_changeset/1" do
    test "returns changeset as is" do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = AccountsFixtures.create_account()
      changeset = %Ecto.Changeset{data: %Domain.Auth.Provider{account_id: account.id}}
      assert provider_changeset(changeset) == changeset
    end

    test "returns error when email adapter is not configured" do
      account = AccountsFixtures.create_account()
      changeset = %Ecto.Changeset{data: %Domain.Auth.Provider{account_id: account.id}}
      changeset = provider_changeset(changeset)
      assert changeset.errors == [adapter: {"email adapter is not configured", []}]
    end
  end

  describe "ensure_provisioned/1" do
    test "does nothing for a provider" do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)
      provider = AuthFixtures.create_email_provider()
      assert ensure_provisioned(provider) == {:ok, provider}
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)
      provider = AuthFixtures.create_email_provider()
      assert ensure_deprovisioned(provider) == {:ok, provider}
    end
  end

  describe "request_sign_in_token/1" do
    test "returns identity with updated sign-in token" do
      identity = AuthFixtures.create_identity()

      assert {:ok, identity} = request_sign_in_token(identity)

      assert %{
               "sign_in_token_created_at" => sign_in_token_created_at,
               "sign_in_token_hash" => sign_in_token_hash
             } = identity.provider_state

      assert %{
               sign_in_token: sign_in_token
             } = identity.provider_virtual_state

      assert Domain.Crypto.equal?(sign_in_token, sign_in_token_hash)
      assert %DateTime{} = sign_in_token_created_at
    end
  end

  describe "verify_secret/2" do
    setup do
      Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider)
      token = identity.provider_virtual_state.sign_in_token

      %{account: account, provider: provider, identity: identity, token: token}
    end

    test "removes token after it's used", %{
      identity: identity,
      token: token
    } do
      assert {:ok, identity, nil} = verify_secret(identity, token)

      assert identity.provider_state == %{}
      assert identity.provider_virtual_state == %{}
    end

    test "returns error when token is expired", %{
      account: account,
      provider: provider
    } do
      forty_seconds_ago = DateTime.utc_now() |> DateTime.add(-1 * 15 * 60 - 1, :second)

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          provider_state: %{
            "sign_in_token_hash" => Domain.Crypto.hash("dummy_token"),
            "sign_in_token_created_at" => DateTime.to_iso8601(forty_seconds_ago)
          }
        )

      assert verify_secret(identity, "dummy_token") == {:error, :expired_secret}
    end

    test "returns error when token is invalid", %{
      identity: identity
    } do
      assert verify_secret(identity, "foo") == {:error, :invalid_secret}
    end
  end
end
