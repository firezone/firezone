defmodule Domain.Auth.Adapters.TokenTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.Token
  alias Domain.Auth
  alias Domain.{AccountsFixtures, AuthFixtures}

  describe "identity_changeset/2" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_token_provider(account: account)

      %{
        account: account,
        provider: provider
      }
    end

    test "puts secret hash in the provider state", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_virtual_state: %{
            expires_at: DateTime.utc_now() |> DateTime.add(1, :day)
          }
        )

      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert %{provider_state: state, provider_virtual_state: virtual_state} = changeset.changes

      assert %{"secret_hash" => secret_hash} = state
      assert %{secret: secret} = virtual_state
      assert Domain.Crypto.equal?(secret, secret_hash)
    end

    test "returns error on invalid attrs", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_virtual_state: %{
            expires_at: DateTime.utc_now()
          }
        )

      assert changeset = identity_changeset(provider, changeset)

      refute changeset.valid?

      assert %{
               provider_virtual_state: %{
                 expires_at: ["must be greater than " <> _]
               }
             } = errors_on(changeset)
    end

    test "trims provider identifier", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_identifier: " X ",
          provider_virtual_state: %{
            expires_at: DateTime.utc_now() |> DateTime.add(1, :day)
          }
        )

      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert changeset.changes.provider_identifier == "X"
    end
  end

  describe "provider_changeset/1" do
    test "returns changeset as is" do
      changeset = %Ecto.Changeset{}
      assert provider_changeset(changeset) == changeset
    end
  end

  describe "ensure_provisioned/1" do
    test "does nothing for a provider" do
      provider = AuthFixtures.create_token_provider()
      assert ensure_provisioned(provider) == {:ok, provider}
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      provider = AuthFixtures.create_token_provider()
      assert ensure_deprovisioned(provider) == {:ok, provider}
    end
  end

  describe "verify_secret/2" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_token_provider(account: account)

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{
            "expires_at" => DateTime.utc_now() |> DateTime.add(1, :day)
          }
        )

      %{
        account: account,
        provider: provider,
        identity: identity
      }
    end

    test "returns :invalid_secret on invalid secret", %{identity: identity} do
      assert verify_secret(identity, "foo") == {:error, :invalid_secret}
    end

    test "returns :expired_secret on expires secret", %{identity: identity} do
      identity =
        identity
        |> Ecto.Changeset.change(
          provider_state: %{
            "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second),
            "secret_hash" => Domain.Crypto.hash("foo")
          }
        )
        |> Repo.update!()

      assert verify_secret(identity, identity.provider_virtual_state.secret) ==
               {:error, :expired_secret}
    end

    test "returns :ok on valid secret", %{identity: identity} do
      assert {:ok, verified_identity, expires_at} =
               verify_secret(identity, identity.provider_virtual_state.secret)

      assert verified_identity.provider_state["secret_hash"] ==
               identity.provider_state["secret_hash"]

      assert verified_identity.provider_state["expires_at"] ==
               identity.provider_state["expires_at"]

      assert {:ok, ^expires_at, 0} = DateTime.from_iso8601(identity.provider_state["expires_at"])
    end
  end
end
