defmodule Portal.Workers.DeleteExpiredOneTimePasscodesTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Authentication
  alias Portal.OneTimePasscode
  alias Portal.PendingIdentity
  alias Portal.Workers.DeleteExpiredOneTimePasscodes

  describe "perform/1" do
    test "deletes expired one-time passcodes" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)

      {:ok, passcode} = Authentication.create_one_time_passcode(account, actor)

      passcode
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
      |> Repo.update!()

      assert Repo.get_by(OneTimePasscode, id: passcode.id)

      assert :ok = perform_job(DeleteExpiredOneTimePasscodes, %{})

      refute Repo.get_by(OneTimePasscode, id: passcode.id)
    end

    test "does not delete non-expired one-time passcodes" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)

      {:ok, passcode} = Authentication.create_one_time_passcode(account, actor)

      assert Repo.get_by(OneTimePasscode, id: passcode.id)

      assert :ok = perform_job(DeleteExpiredOneTimePasscodes, %{})

      assert Repo.get_by(OneTimePasscode, id: passcode.id)
    end

    test "deletes multiple expired passcodes across accounts" do
      account1 = account_fixture()
      actor1 = actor_fixture(account: account1, type: :account_admin_user)

      account2 = account_fixture()
      actor2 = actor_fixture(account: account2, type: :account_admin_user)

      {:ok, passcode1} = Authentication.create_one_time_passcode(account1, actor1)
      {:ok, passcode2} = Authentication.create_one_time_passcode(account2, actor2)

      for passcode <- [passcode1, passcode2] do
        passcode
        |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteExpiredOneTimePasscodes, %{})

      refute Repo.get_by(OneTimePasscode, id: passcode1.id)
      refute Repo.get_by(OneTimePasscode, id: passcode2.id)
    end

    test "deletes pending identities through one-time passcode cascade" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)
      auth_provider = auth_provider_fixture(account: account, type: :oidc)

      {:ok, passcode} = Authentication.create_one_time_passcode(account, actor)

      pending_identity =
        %PendingIdentity{}
        |> Ecto.Changeset.cast(
          %{
            id: Ecto.UUID.generate(),
            account_id: account.id,
            actor_id: actor.id,
            auth_provider_id: auth_provider.id,
            one_time_passcode_id: passcode.id,
            issuer: "https://idp.example.com",
            idp_id: "user-123",
            email: actor.email,
            name: actor.name
          },
          [
            :id,
            :account_id,
            :actor_id,
            :auth_provider_id,
            :one_time_passcode_id,
            :issuer,
            :idp_id,
            :email,
            :name
          ]
        )
        |> PendingIdentity.changeset()
        |> Repo.insert!()

      passcode
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
      |> Repo.update!()

      assert :ok = perform_job(DeleteExpiredOneTimePasscodes, %{})

      refute Repo.get_by(OneTimePasscode, id: passcode.id)
      refute Repo.get_by(PendingIdentity, id: pending_identity.id)
    end
  end
end
