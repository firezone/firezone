defmodule Portal.ApplicationTest do
  use ExUnit.Case, async: true

  require Logger

  describe "start/2" do
    test "geolix databases are loaded before supervision tree starts" do
      for %{id: id} <- Portal.Config.get_env(:geolix, :databases, []) do
        assert Geolix.metadata(where: id) != nil,
               "expected Geolix database #{inspect(id)} to be loaded"
      end
    end

    test "Oban descendants inherit the configured job repo" do
      oban_repo = Application.fetch_env!(:portal, Oban) |> Keyword.fetch!(:repo)
      ancestors = Process.get(:"$ancestors", [])

      Process.put(:"$ancestors", [Portal.Oban])

      try do
        assert Portal.Repo.DynamicRepoResolver.inherit(Portal.Repo) == oban_repo
      after
        Process.put(:"$ancestors", ancestors)
      end
    end
  end

  describe "Sentry logger handler" do
    setup do
      Sentry.Test.start_collecting_sentry_reports()
    end

    test "reports request crashes that Bandit logs" do
      reason = %RuntimeError{message: "boom"}
      metadata = Bandit.Logger.logger_metadata_for(:error, reason, [], [])

      Logger.error(Exception.format(:error, reason, []), metadata)

      assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    end

    test "reports warnings" do
      Logger.warning("something looks wrong")

      assert [%Sentry.Event{level: :warning}] = Sentry.Test.pop_sentry_reports()
    end

    test "reports errors" do
      Logger.error("something went wrong")

      assert [%Sentry.Event{level: :error}] = Sentry.Test.pop_sentry_reports()
    end

    test "does not report info messages" do
      Logger.info("all good")

      assert Sentry.Test.pop_sentry_reports() == []
    end
  end

  describe "stop/1" do
    test "removes logger handler without crashing" do
      # Use a unique handler ID to avoid conflicts with parallel tests
      handler_id = :"test_handler_#{:erlang.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler_id, Sentry.LoggerHandler, %{
          config: %{
            capture_level: :warning,
            capture_metadata: :all,
            capture_log_messages: true,
            capture_excluded_domains: []
          }
        })

      assert handler_id in :logger.get_handler_ids()

      # This is the same call made in Portal.Application.stop/1
      assert :ok = :logger.remove_handler(handler_id)

      refute handler_id in :logger.get_handler_ids()
    end

    test "does not crash when handler is already removed" do
      handler_id = :"test_handler_#{:erlang.unique_integer([:positive])}"

      # Handler doesn't exist - remove_handler returns error but doesn't crash
      # Portal.Application.stop/1 ignores this return value with `_ =`
      assert {:error, {:not_found, ^handler_id}} = :logger.remove_handler(handler_id)
    end
  end

  # Note: prep_stop/1 cannot be easily unit tested because it calls
  # Supervisor.stop/3 on the Repo processes, which would break the test
  # environment's DBConnection.Ownership sandbox mode.
end
