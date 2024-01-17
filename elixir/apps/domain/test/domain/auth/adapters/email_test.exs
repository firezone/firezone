defmodule Domain.Auth.Adapters.EmailTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.Email
  alias Domain.Auth

  describe "identity_changeset/2" do
    setup do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      changeset = %Auth.Identity{} |> Ecto.Changeset.change()

      %{
        account: account,
        provider: provider,
        changeset: changeset
      }
    end

    test "puts empty provider state by default", %{provider: provider, changeset: changeset} do
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)

      assert changeset.changes == %{
               provider_state: %{},
               provider_virtual_state: %{}
             }
    end

    test "trims provider identifier", %{provider: provider, changeset: changeset} do
      changeset = Ecto.Changeset.put_change(changeset, :provider_identifier, " X ")
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert changeset.changes.provider_identifier == "X"
    end

    test "validates email confirmation", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.cast(
          %{
            provider_identifier: Fixtures.Auth.email(),
            provider_identifier_confirmation: ""
          },
          [:provider_identifier]
        )

      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)

      assert changeset.errors == [
               provider_identifier_confirmation:
                 {"email does not match", [validation: :confirmation]}
             ]
    end
  end

  describe "provider_changeset/1" do
    test "returns changeset as is" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      account = Fixtures.Accounts.create_account()
      changeset = %Ecto.Changeset{data: %Domain.Auth.Provider{account_id: account.id}}
      assert provider_changeset(changeset) == changeset
    end

    test "returns error when email adapter is not configured" do
      account = Fixtures.Accounts.create_account()
      changeset = %Ecto.Changeset{data: %Domain.Auth.Provider{account_id: account.id}}
      changeset = provider_changeset(changeset)
      assert changeset.errors == [adapter: {"email adapter is not configured", []}]
    end
  end

  describe "ensure_provisioned/1" do
    test "does nothing for a provider" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider()
      assert ensure_provisioned(provider) == {:ok, provider}
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider()
      assert ensure_deprovisioned(provider) == {:ok, provider}
    end
  end

  describe "request_sign_in_token/1" do
    test "returns identity with valid token components" do
      identity = Fixtures.Auth.create_identity()
      context = Fixtures.Auth.build_context(type: :email)

      assert {:ok, identity} = request_sign_in_token(identity, context)

      assert %{
               "last_created_token_id" => token_id
             } = identity.provider_state

      assert %{
               nonce: nonce,
               fragment: fragment
             } = identity.provider_virtual_state

      token = Repo.get(Domain.Tokens.Token, token_id)
      assert token.type == :email
      assert token.account_id == identity.account_id
      assert token.actor_id == identity.actor_id
      assert token.identity_id == identity.id
      assert token.remaining_attempts == 5

      assert {:ok, token} = Domain.Tokens.use_token(nonce <> fragment, context)
      assert token.id == token_id
      assert token.remaining_attempts == 4
    end

    test "deletes previous sign in tokens" do
      identity = Fixtures.Auth.create_identity()
      context = Fixtures.Auth.build_context(type: :email)

      assert {:ok, identity} = request_sign_in_token(identity, context)
      assert %{"last_created_token_id" => first_token_id} = identity.provider_state

      assert {:ok, identity} = request_sign_in_token(identity, context)
      assert %{"last_created_token_id" => second_token_id} = identity.provider_state

      assert Repo.get(Domain.Tokens.Token, first_token_id).deleted_at
      refute Repo.get(Domain.Tokens.Token, second_token_id).deleted_at
    end
  end

  describe "verify_secret/3" do
    setup do
      context = Fixtures.Auth.build_context(type: :email)
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = request_sign_in_token(identity, context)

      nonce = identity.provider_virtual_state.nonce
      fragment = identity.provider_virtual_state.fragment

      %{
        account: account,
        provider: provider,
        identity: identity,
        token: nonce <> fragment,
        context: context
      }
    end

    test "removes all pending tokens after one is used", %{
      account: account,
      identity: identity,
      context: context,
      token: token
    } do
      other_token =
        Fixtures.Tokens.create_token(
          type: :email,
          account: account,
          identity: identity
        )

      assert {:ok, identity, nil} = verify_secret(identity, context, token)

      assert %{last_used_token_id: token_id} = identity.provider_state
      assert identity.provider_virtual_state == %{}

      token = Repo.get(Domain.Tokens.Token, token_id)
      assert token.deleted_at

      token = Repo.get(Domain.Tokens.Token, other_token.id)
      assert token.deleted_at
    end

    test "returns error when token is expired", %{
      context: context,
      identity: identity,
      token: token
    } do
      Repo.get(Domain.Tokens.Token, identity.provider_state["last_created_token_id"])
      |> Fixtures.Tokens.expire_token()

      assert verify_secret(identity, context, token) == {:error, :invalid_secret}
    end

    test "returns error when token is invalid", %{
      context: context,
      identity: identity
    } do
      assert verify_secret(identity, context, "foo") == {:error, :invalid_secret}
    end
  end
end
