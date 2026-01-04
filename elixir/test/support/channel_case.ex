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

  @doc """
  Generates a unique random IP address for test isolation.
  """
  def unique_ip do
    {:rand.uniform(255), :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end

  @geo_headers [
    {"x-geo-location-region", "Ukraine"},
    {"x-geo-location-city", "Kyiv"},
    {"x-geo-location-coordinates", "50.4333,30.5167"}
  ]

  @doc """
  Builds connect_info for socket tests with rate limiting isolation.

  Options:
    * `:ip` - IP address tuple (default: random)
    * `:token` - Authorization token to include in headers
    * `:user_agent` - User agent string (default: "iOS/12.7 connlib/1.3.0")
    * `:x_headers` - Custom x_headers that REPLACE the default geo headers
  """
  def build_connect_info(opts \\ []) do
    ip = Keyword.get(opts, :ip, unique_ip())
    token = Keyword.get(opts, :token)
    user_agent = Keyword.get(opts, :user_agent, "iOS/12.7 connlib/1.3.0")
    custom_headers = Keyword.get(opts, :x_headers)

    # If custom headers are provided, use those; otherwise use default geo headers
    geo_headers =
      if custom_headers do
        custom_headers
      else
        @geo_headers
      end

    base_headers = [{"x-forwarded-for", :inet.ntoa(ip) |> to_string()} | geo_headers]

    x_headers =
      if token do
        [{"x-authorization", "Bearer #{token}"} | base_headers]
      else
        base_headers
      end

    %{
      user_agent: user_agent,
      peer_data: %{address: ip},
      x_headers: x_headers,
      trace_context_headers: []
    }
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
