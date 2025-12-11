defmodule Domain.Workers.DeleteExpiredOneTimePasscodesTest do
  use Domain.DataCase, async: true
  use Oban.Testing, repo: Domain.Repo

  import Domain.AccountFixtures
  import Domain.ActorFixtures

  alias Domain.Auth
  alias Domain.OneTimePasscode
  alias Domain.Workers.DeleteExpiredOneTimePasscodes

  describe "perform/1" do
    test "deletes expired one-time passcodes" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)

      # Create a passcode and manually expire it
      {:ok, passcode} = Auth.create_one_time_passcode(account, actor)

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

      {:ok, passcode} = Auth.create_one_time_passcode(account, actor)

      assert Repo.get_by(OneTimePasscode, id: passcode.id)

      assert :ok = perform_job(DeleteExpiredOneTimePasscodes, %{})

      assert Repo.get_by(OneTimePasscode, id: passcode.id)
    end

    test "deletes multiple expired passcodes across accounts" do
      account1 = account_fixture()
      actor1 = actor_fixture(account: account1, type: :account_admin_user)

      account2 = account_fixture()
      actor2 = actor_fixture(account: account2, type: :account_admin_user)

      {:ok, passcode1} = Auth.create_one_time_passcode(account1, actor1)
      {:ok, passcode2} = Auth.create_one_time_passcode(account2, actor2)

      # Expire both passcodes
      for passcode <- [passcode1, passcode2] do
        passcode
        |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteExpiredOneTimePasscodes, %{})

      refute Repo.get_by(OneTimePasscode, id: passcode1.id)
      refute Repo.get_by(OneTimePasscode, id: passcode2.id)
    end
  end
end
