defmodule Portal.ApplicationTest do
  use ExUnit.Case, async: true

  describe "start/2" do
    test "geolix databases are loaded before supervision tree starts" do
      for %{id: id} <- Portal.Config.get_env(:geolix, :databases, []) do
        assert Geolix.metadata(where: id) != nil,
               "expected Geolix database #{inspect(id)} to be loaded"
      end
    end
  end

  describe "stop/1" do
    test "removes logger handler without crashing" do
      # Use a unique handler ID to avoid conflicts with parallel tests
      handler_id = :"test_handler_#{:erlang.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler_id, Sentry.LoggerHandler, %{
          config: %{
            level: :warning,
            metadata: :all,
            capture_log_messages: true
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
