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

    test "routes Intune device inventory sync exceptions to the Intune error handler" do
      integration = Portal.IntuneFixtures.intune_integration_fixture()

      job = %Oban.Job{
        id: 2,
        worker: "Portal.Intune.Sync",
        queue: "intune_sync",
        meta: %{},
        args: %{"device_integration_id" => integration.id}
      }

      reason =
        Portal.Intune.SyncError.exception(
          integration_id: integration.id,
          step: :list_managed_devices,
          error: %Req.Response{status: 403, body: ""}
        )

      Reporter.handle_event([:oban, :job, :exception], %{}, %{reason: reason, job: job, stacktrace: []}, [])

      assert Portal.Repo.get_by!(Portal.Intune.Integration,
               account_id: integration.account_id,
               id: integration.id
             ).is_disabled
    end
  end
end
