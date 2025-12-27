defmodule PortalAPI.ChannelCase do
  use ExUnit.CaseTemplate
  use Portal.CaseTemplate

  @presences [
    Portal.Presence
  ]

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import PortalAPI.ChannelCase
      alias Portal.Repo
      alias Portal.Fixtures
      require OpenTelemetry.Tracer

      # The default endpoint for testing
      @endpoint PortalAPI.Endpoint
    end
  end

  setup tags do
    # Isolate relay presence per test to prevent interference between async tests
    Portal.Config.put_env_override(
      :portal,
      :relay_presence_topic,
      "presences:global_relays:#{inspect(make_ref())}"
    )

    # Set debounce to 0 in tests for faster execution
    Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 0)

    for presence <- @presences, pid <- presence.fetchers_pids() do
      # TODO: If we start using Presence.fetch/2 callback we might want to
      # contribute to Phoenix.Presence a way to propagate sandbox access from
      # the parent to the task supervisor it spawns in start_link/1 every time
      # it's used. Because this would not work as is:
      # Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, self(), pid)

      on_exit(fn ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, _, _, _}, 1000
      end)
    end

    tags
  end
end
