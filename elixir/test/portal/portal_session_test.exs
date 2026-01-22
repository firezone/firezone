defmodule Portal.PortalSessionTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias Portal.PortalSession

  describe "changeset/1 association constraints" do
    test "enforces actor association constraint" do
      account = account_fixture()
      auth_provider = email_otp_provider_fixture(account: account).auth_provider

      {:error, changeset} =
        %PortalSession{}
        |> cast(
          %{
            actor_id: Ecto.UUID.generate(),
            auth_provider_id: auth_provider.id,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [:actor_id, :auth_provider_id, :expires_at]
        )
        |> put_assoc(:account, account)
        |> PortalSession.changeset()
        |> Repo.insert()

      assert %{actor: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces auth_provider association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:error, changeset} =
        %PortalSession{}
        |> cast(
          %{
            auth_provider_id: Ecto.UUID.generate(),
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [:auth_provider_id, :expires_at]
        )
        |> put_assoc(:account, account)
        |> put_assoc(:actor, actor)
        |> PortalSession.changeset()
        |> Repo.insert()

      assert %{auth_provider: ["does not exist"]} = errors_on(changeset)
    end

    test "allows valid associations" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = email_otp_provider_fixture(account: account).auth_provider

      {:ok, session} =
        %PortalSession{}
        |> cast(
          %{
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          [:expires_at]
        )
        |> put_assoc(:account, account)
        |> put_assoc(:actor, actor)
        |> put_assoc(:auth_provider, auth_provider)
        |> PortalSession.changeset()
        |> Repo.insert()

      assert session.account_id == account.id
      assert session.actor_id == actor.id
      assert session.auth_provider_id == auth_provider.id
    end
  end
end
