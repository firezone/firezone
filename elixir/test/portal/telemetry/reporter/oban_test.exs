defmodule Portal.Telemetry.Reporter.ObanTest do
  use Portal.DataCase, async: true

  alias Portal.Telemetry.Reporter.Oban, as: Reporter

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  describe "handle_event/4" do
    setup do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account)

      %{directory: directory}
    end

    test "captures directory sync exceptions without raising the telemetry handler",
         %{directory: directory} do
      job = %Oban.Job{
        id: 1,
        worker: "Portal.Entra.Sync",
        queue: "directory_sync",
        meta: %{},
        args: %{"directory_id" => directory.id}
      }

      reason = %Portal.Entra.SyncError{
        error: %Req.HTTPError{protocol: :http2, reason: :pool_not_available},
        directory_id: directory.id,
        step: :get_access_token
      }

      meta = %{reason: reason, job: job, stacktrace: []}

      Reporter.handle_event([:oban, :job, :exception], %{}, meta, [])

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.errored_at != nil
    end
  end
end
