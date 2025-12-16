defmodule Domain.Workers.DeleteExpiredAPITokensTest do
  use Domain.DataCase, async: true
  use Oban.Testing, repo: Domain.Repo

  import Domain.APITokenFixtures

  alias Domain.APIToken
  alias Domain.Workers.DeleteExpiredAPITokens

  describe "perform/1" do
    test "deletes expired API tokens" do
      token = api_token_fixture()

      token
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
      |> Repo.update!()

      assert Repo.get_by(APIToken, id: token.id)

      assert :ok = perform_job(DeleteExpiredAPITokens, %{})

      refute Repo.get_by(APIToken, id: token.id)
    end

    test "does not delete non-expired API tokens" do
      token = api_token_fixture()

      assert Repo.get_by(APIToken, id: token.id)

      assert :ok = perform_job(DeleteExpiredAPITokens, %{})

      assert Repo.get_by(APIToken, id: token.id)
    end

    test "deletes multiple expired tokens across accounts" do
      token1 = api_token_fixture()
      token2 = api_token_fixture()

      for token <- [token1, token2] do
        token
        |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteExpiredAPITokens, %{})

      refute Repo.get_by(APIToken, id: token1.id)
      refute Repo.get_by(APIToken, id: token2.id)
    end
  end
end
