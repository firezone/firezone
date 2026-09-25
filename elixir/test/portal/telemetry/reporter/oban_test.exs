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

  describe "posture sync Sentry reporting" do
    setup do
      Sentry.Test.start_collecting_sentry_reports()
    end

    for {adapter, fixtures, fixture} <- [
          {Portal.Intune, Portal.IntuneFixtures, :intune_posture_provider_fixture},
          {Portal.Defender, Portal.DefenderFixtures, :defender_posture_provider_fixture},
          {Portal.Iru, Portal.IruFixtures, :iru_posture_provider_fixture},
          {Portal.Santa, Portal.SantaFixtures, :santa_posture_provider_fixture},
          {Portal.SentinelOne, Portal.SentinelOneFixtures, :sentinelone_posture_provider_fixture}
        ] do
      @adapter adapter
      @fixtures fixtures
      @fixture fixture

      test "#{adapter} keeps transient errors quiet during the recovery window" do
        errored_at = DateTime.add(DateTime.utc_now(), -23, :hour)
        provider = apply(@fixtures, @fixture, [[errored_at: errored_at]])
        reason = posture_error(@adapter, provider, 503)

        report_posture_error(@adapter, provider, reason)
        assert Sentry.Test.pop_sentry_reports() == []

        updated = reload_posture_provider(@adapter, provider)
        refute updated.is_disabled
        assert updated.errored_at == errored_at
        assert updated.error_message =~ "503"
      end

      test "#{adapter} reports once when transient errors disable the provider" do
        provider =
          apply(@fixtures, @fixture, [[errored_at: DateTime.add(DateTime.utc_now(), -24, :hour)]])
        reason = posture_error(@adapter, provider, 503)

        report_posture_error(@adapter, provider, reason)
        assert [%Sentry.Event{original_exception: ^reason}] = Sentry.Test.pop_sentry_reports()
        assert reload_posture_provider(@adapter, provider).is_disabled

        report_posture_error(@adapter, provider, reason)
        assert Sentry.Test.pop_sentry_reports() == []
      end

      test "#{adapter} reports permanent errors immediately" do
        provider = apply(@fixtures, @fixture, [])
        reason = posture_error(@adapter, provider, 403)

        report_posture_error(@adapter, provider, reason)
        assert [%Sentry.Event{original_exception: ^reason}] = Sentry.Test.pop_sentry_reports()
        assert reload_posture_provider(@adapter, provider).is_disabled
      end
    end

    test "unexpected worker crashes are reported immediately" do
      provider = Portal.DefenderFixtures.defender_posture_provider_fixture()
      reason = %RuntimeError{message: "unexpected crash"}

      report_posture_error(Portal.Defender, provider, reason)
      assert [%Sentry.Event{original_exception: ^reason}] = Sentry.Test.pop_sentry_reports()
    end
  end

  defp reload_posture_provider(adapter, provider) do
    Repo.get_by!(Module.concat(adapter, PostureProvider),
      account_id: provider.account_id,
      id: provider.id
    )
  end

  defp posture_error(adapter, provider, status) do
    Module.concat(adapter, SyncError).exception(
      provider_id: provider.id,
      step: :list_devices,
      error: %Req.Response{status: status, body: "upstream error"}
    )
  end

  defp report_posture_error(adapter, provider, reason) do
    job = %Oban.Job{
      id: 10,
      worker: adapter |> Module.concat(Sync) |> inspect(),
      queue: "posture_sync",
      meta: %{},
      args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
    }

    Reporter.handle_event([:oban, :job, :exception], %{}, %{reason: reason, job: job, stacktrace: []}, [])
  end
end
