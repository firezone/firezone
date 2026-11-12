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
      import Portal.Test.Assertions
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
    * `:host` - Request host, as `connect_info.uri` carries it
    * `:client_cert` - DER-encoded TLS peer certificate
  """
  def build_connect_info(opts \\ []) do
    ip = Keyword.get(opts, :ip, unique_ip())
    token = Keyword.get(opts, :token)
    user_agent = Keyword.get(opts, :user_agent, "iOS/12.7 connlib/1.3.0")
    host = Keyword.get(opts, :host, "api.firezone.test")
    client_cert = Keyword.get(opts, :client_cert)
    custom_headers = Keyword.get(opts, :x_headers)

    # If custom headers are provided, use those; otherwise use default geo headers
    geo_headers =
      if custom_headers do
        custom_headers
      else
        @geo_headers
      end

    x_headers =
      [{"x-forwarded-for", :inet.ntoa(ip) |> to_string()} | geo_headers]
      |> prepend_header(token && {"x-authorization", "Bearer #{token}"})

    %{
      user_agent: user_agent,
      peer_data: %{address: ip, ssl_cert: client_cert},
      x_headers: x_headers,
      uri: %URI{scheme: "https", host: host, port: 443, path: "/"},
      trace_context_headers: []
    }
  end

  @doc """
  Runs `fun` once, in the querying process, right after the first query on the
  `source` table whose parameters include `id`.
  """
  def after_query(source, id, fun) do
    handler_id = {__MODULE__, make_ref()}
    config = %{handler_id: handler_id, source: source, params: [id, Ecto.UUID.dump!(id)], fun: fun}
    :ok = :telemetry.attach(handler_id, [:portal, :repo, :query], &__MODULE__.handle_query/4, config)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_query(_event, _measurements, %{source: source, params: params}, %{source: source} = config) do
    if Enum.any?(config.params, &(&1 in params)) and :telemetry.detach(config.handler_id) == :ok do
      config.fun.()
    end
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Sends `{:trace, pid, :call, mfa}` to the test process for each call to `mfas`
  that the querying process makes after the query matched by `after_query/3`.
  """
  def trace_calls_after_query(source, id, mfas) do
    session = :trace.session_create(__MODULE__, self(), [])
    ExUnit.Callbacks.on_exit(fn -> :trace.session_destroy(session) end)
    for mfa <- mfas, do: :trace.function(session, mfa, true, [:local])
    after_query(source, id, fn -> :trace.process(session, self(), true, [:call]) end)
  end

  setup tags do
    # Isolate pg channels scope per test to prevent interference between async tests
    scope = :"Portal.PG.#{inspect(make_ref())}"
    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})
    Portal.Config.put_env_override(:portal, :pg_scope, scope)

    # Isolate relay presence per test to prevent interference between async tests
    Portal.Config.put_env_override(
      :portal,
      :relay_presence_topic,
      "presences:relays:#{inspect(make_ref())}"
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

    Map.put(tags, :pg_scope, scope)
  end

  defp prepend_header(headers, nil), do: headers
  defp prepend_header(headers, header), do: [header | headers]
end
