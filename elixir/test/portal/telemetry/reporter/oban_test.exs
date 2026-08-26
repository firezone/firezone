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
      provider = Portal.IntuneFixtures.intune_posture_provider_fixture()

      job = %Oban.Job{
        id: 2,
        worker: "Portal.Intune.Sync",
        queue: "intune_sync",
        meta: %{},
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      }

      reason =
        Portal.Intune.SyncError.exception(
          provider_id: provider.id,
          step: :list_managed_devices,
          error: %Req.Response{status: 403, body: ""}
        )

      Reporter.handle_event([:oban, :job, :exception], %{}, %{reason: reason, job: job, stacktrace: []}, [])

      assert Portal.Repo.get_by!(Portal.Intune.PostureProvider,
               account_id: provider.account_id,
               id: provider.id
             ).is_disabled
    end

    test "routes Iru device inventory sync exceptions to the Iru error handler" do
      provider = Portal.IruFixtures.iru_posture_provider_fixture()

      job = %Oban.Job{
        id: 3,
        worker: "Portal.Iru.Sync",
        queue: "iru_sync",
        meta: %{},
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      }

      reason =
        Portal.Iru.SyncError.exception(
          provider_id: provider.id,
          step: :list_devices,
          error: %Req.Response{status: 403, body: ""}
        )

      Reporter.handle_event([:oban, :job, :exception], %{}, %{reason: reason, job: job, stacktrace: []}, [])

      assert Portal.Repo.get_by!(Portal.Iru.PostureProvider,
               account_id: provider.account_id,
               id: provider.id
             ).is_disabled
    end

    test "routes Defender device inventory sync exceptions to the Defender error handler" do
      provider = Portal.DefenderFixtures.defender_posture_provider_fixture()

      job = %Oban.Job{
        id: 4,
        worker: "Portal.Defender.Sync",
        queue: "defender_sync",
        meta: %{},
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      }

      reason =
        Portal.Defender.SyncError.exception(
          provider_id: provider.id,
          step: :list_machines,
          error: %Req.Response{status: 403, body: %{}}
        )

      Reporter.handle_event([:oban, :job, :exception], %{}, %{reason: reason, job: job, stacktrace: []}, [])

      assert Portal.Repo.get_by!(Portal.Defender.PostureProvider,
               account_id: provider.account_id,
               id: provider.id
             ).is_disabled
    end

    test "routes Santa device inventory sync exceptions to the Santa error handler" do
      provider = Portal.SantaFixtures.santa_posture_provider_fixture()

      job = %Oban.Job{
        id: 4,
        worker: "Portal.Santa.Sync",
        queue: "santa_sync",
        meta: %{},
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      }

      reason =
        Portal.Santa.SyncError.exception(
          provider_id: provider.id,
          step: :list_hosts,
          error: %Req.Response{status: 403, body: ""}
        )

      Reporter.handle_event(
        [:oban, :job, :exception],
        %{},
        %{reason: reason, job: job, stacktrace: []},
        []
      )

      assert Portal.Repo.get_by!(Portal.Santa.PostureProvider,
               account_id: provider.account_id,
               id: provider.id
             ).is_disabled
    end
  end
end
