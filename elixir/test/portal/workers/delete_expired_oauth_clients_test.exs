defmodule Portal.Workers.DeleteExpiredOAuthClientsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.OAuthFixtures

  alias Portal.OAuthClient
  alias Portal.Workers.DeleteExpiredOAuthClients

  @stale DateTime.add(DateTime.utc_now(), -2, :hour)

  describe "perform/1" do
    test "deletes stale clients nothing points at" do
      client = oauth_client_fixture(metadata_expires_at: @stale)

      assert :ok = perform_job(DeleteExpiredOAuthClients, %{})

      refute Repo.get(OAuthClient, client.id)
    end

    test "keeps a client that is still fresh" do
      client = oauth_client_fixture()

      assert :ok = perform_job(DeleteExpiredOAuthClients, %{})

      assert Repo.get(OAuthClient, client.id)
    end

    test "keeps a client that only just expired" do
      client = oauth_client_fixture(metadata_expires_at: DateTime.add(DateTime.utc_now(), -1, :minute))

      assert :ok = perform_job(DeleteExpiredOAuthClients, %{})

      assert Repo.get(OAuthClient, client.id)
    end

    test "keeps a stale client that a grant points at" do
      client = oauth_client_fixture(metadata_expires_at: @stale)
      oauth_grant_fixture(client: client)

      assert :ok = perform_job(DeleteExpiredOAuthClients, %{})

      assert Repo.get(OAuthClient, client.id)
    end
  end
end
