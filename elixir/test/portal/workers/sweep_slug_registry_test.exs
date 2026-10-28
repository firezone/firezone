defmodule Portal.Workers.SweepSlugRegistryTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import Plug.Conn
  import Portal.AccountFixtures
  import Portal.SlugRegistryHelpers

  alias Portal.Workers.SweepSlugRegistry

  test "does nothing with the local registry" do
    assert :ok = perform_job(SweepSlugRegistry, %{})
  end

  test "releases old claims of this region that have no local row" do
    account = account_fixture(slug: "kept-slug")
    use_azure_registry(:us)
    orphan_account_id = Ecto.UUID.generate()
    old = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.to_iso8601()
    fresh = DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.to_iso8601()
    test_pid = self()

    stub_registry(fn
      %{method: "GET", request_path: "/slugs()"} = conn ->
        Req.Test.json(conn, %{
          "value" => [
            Map.put(entity("kept-slug", account.id, "us"), "InsertedAt", old),
            Map.put(entity("orphan-old", orphan_account_id, "us"), "InsertedAt", old),
            Map.put(entity("orphan-fresh", orphan_account_id, "us"), "InsertedAt", fresh)
          ]
        })

      %{method: "GET"} = conn ->
        Req.Test.json(conn, entity(row_key(conn), orphan_account_id, "us"))

      %{method: "DELETE"} = conn ->
        send(test_pid, {:deleted, row_key(conn)})
        send_resp(conn, 204, "")
    end)

    assert :ok = perform_job(SweepSlugRegistry, %{})

    assert_received {:deleted, "orphan-old"}
    refute_received {:deleted, "orphan-fresh"}
    refute_received {:deleted, "kept-slug"}
  end
end
