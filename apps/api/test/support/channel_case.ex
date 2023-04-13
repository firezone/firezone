defmodule API.ChannelCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate

  @presences [
    Domain.Clients.Presence,
    Domain.Gateways.Presence,
    Domain.Relays.Presence
  ]

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import API.ChannelCase
      alias Domain.Repo

      # The default endpoint for testing
      @endpoint API.Endpoint
    end
  end

  setup tags do
    for presence <- @presences, pid <- presence.fetchers_pids() do
      # XXX: If we start using Presence.fetch/2 callback we might want to
      # contribute to Phoenix.Presence a way to propagate sandbox access from
      # the parent to the task supervisor it spawns in start_link/1 every time
      # it's used. Because this would not work as is:
      # Ecto.Adapters.SQL.Sandbox.allow(Domain.Repo, self(), pid)

      on_exit(fn ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, _, _, _}, 1000
      end)
    end

    tags
  end
end
