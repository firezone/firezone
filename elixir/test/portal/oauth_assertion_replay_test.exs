defmodule Portal.OAuth.AssertionReplayTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Portal.OAuth.ClientAuthentication.Database
  alias Portal.Repo

  test "replay protection is atomic across independent database connections" do
    client_id = "https://client.example.com/#{Ecto.UUID.generate()}.json"
    jti = Ecto.UUID.generate()
    id = :crypto.hash(:sha256, :erlang.term_to_binary({client_id, jti}))
    expires_at = System.system_time(:second) + 120

    try do
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Database.consume_assertion(client_id, jti, expires_at)
            end)
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == :error)) == 1
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(a in "oauth_client_assertions", where: a.id == ^id))
      end)
    end
  end
end
