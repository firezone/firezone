defmodule Domain.Auth.Adapters.UserPassTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.UserPass
  alias Domain.Auth

  describe "identity_changeset/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      %{
        account: account,
        provider: provider
      }
    end

    test "puts password hash in the provider state", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_virtual_state: %{
            password: "Firezone1234",
            password_confirmation: "Firezone1234"
          }
        )

      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert %{provider_state: state, provider_virtual_state: %{}} = changeset.changes

      assert %{"password_hash" => password_hash} = state
      assert Domain.Crypto.equal?(:argon2, "Firezone1234", password_hash)
    end

    test "returns error on invalid attrs", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_virtual_state: %{
            password: "short",
            password_confirmation: nil
          }
        )

      assert changeset = identity_changeset(provider, changeset)

      refute changeset.valid?

      assert errors_on(changeset) == %{
               provider_virtual_state: %{
                 password: ["should be at least 12 byte(s)"],
                 password_confirmation: ["does not match confirmation", "can't be blank"]
               }
             }

      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_virtual_state: %{
            password: "Firezone1234",
            password_confirmation: "FirezoneDoesNotMatch"
          }
        )

      assert changeset = identity_changeset(provider, changeset)

      refute changeset.valid?

      assert errors_on(changeset) == %{
               provider_virtual_state: %{
                 password_confirmation: ["does not match confirmation"]
               }
             }
    end

    test "trims provider identifier", %{provider: provider} do
      changeset =
        %Auth.Identity{}
        |> Ecto.Changeset.change(
          provider_identifier: " X ",
          provider_virtual_state: %{
            password: "Firezone1234",
            password_confirmation: "Firezone1234"
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
      provider = Fixtures.Auth.create_userpass_provider()
      assert ensure_provisioned(provider) == {:ok, provider}
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      provider = Fixtures.Auth.create_userpass_provider()
      assert ensure_deprovisioned(provider) == {:ok, provider}
    end
  end

  describe "verify_secret/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{
            "password" => "Firezone1234",
            "password_confirmation" => "Firezone1234"
          }
        )

      context = Fixtures.Auth.build_context()

      %{
        account: account,
        provider: provider,
        identity: identity,
        context: context
      }
    end

    test "returns :invalid_secret on invalid password", %{identity: identity, context: context} do
      assert verify_secret(identity, context, "FirezoneInvalid") == {:error, :invalid_secret}
    end

    test "returns :ok on valid password", %{identity: identity, context: context} do
      assert {:ok, verified_identity, nil} = verify_secret(identity, context, "Firezone1234")

      assert verified_identity.provider_state["password_hash"] ==
               identity.provider_state["password_hash"]
    end
  end
end
