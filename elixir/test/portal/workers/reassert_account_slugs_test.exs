defmodule Portal.Workers.ReassertAccountSlugsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import ExUnit.CaptureLog
  import Plug.Conn
  import Portal.AccountFixtures
  import Portal.SlugRegistryHelpers

  alias Portal.Workers.ReassertAccountSlugs

  test "does nothing with the local registry" do
    account_fixture()

    assert :ok = perform_job(ReassertAccountSlugs, %{})
  end

  test "claims every local slug in the registry again" do
    account = account_fixture(slug: "reassert-me")
    update_account(account, slug: "reassert-me-too")
    use_azure_registry(:us)
    test_pid = self()

    stub_registry(fn
      %{method: "POST", request_path: "/slugs"} = conn ->
        send(test_pid, {:claimed, json_body(conn)["RowKey"]})
        send_resp(conn, 204, "")
    end)

    assert :ok = perform_job(ReassertAccountSlugs, %{})

    assert_received {:claimed, "reassert-me"}
    assert_received {:claimed, "reassert-me-too"}
  end

  test "logs a slug that another account holds and goes on" do
    account = account_fixture(slug: "contested")
    use_azure_registry(:us)

    stub_registry(fn
      %{method: "POST"} = conn -> send_resp(conn, 409, "")
      %{method: "GET"} = conn -> Req.Test.json(conn, entity("contested", Ecto.UUID.generate(), "eu"))
    end)

    log = capture_log(fn -> assert :ok = perform_job(ReassertAccountSlugs, %{}) end)

    assert log =~ "registered to another account"
    assert log =~ account.id
  end

  test "fails the job when the registry is unavailable" do
    account_fixture()
    use_azure_registry(:us)
    stub_registry(fn conn -> send_resp(conn, 503, "") end)

    capture_log(fn ->
      assert {:error, :slug_registry_unavailable} = perform_job(ReassertAccountSlugs, %{})
    end)
  end
end
