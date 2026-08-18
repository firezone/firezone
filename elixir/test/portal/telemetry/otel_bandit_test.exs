defmodule Portal.Telemetry.OtelBanditTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Portal.Telemetry.OtelBandit

  defmodule ClosedSocketAdapter do
    def get_peer_data(_payload) do
      raise %Bandit.TransportError{message: "Unable to obtain peer_data", error: :einval}
    end
  end

  defmodule BrokenAdapter do
    def get_peer_data(_payload), do: raise(ArgumentError, "handler bug")
  end

  setup_all do
    :ok = OpentelemetryBandit.setup(handler_id: :otel_bandit_test_config)
    handler_id = {OpentelemetryBandit, :otel_bandit_test_config}

    %{config: config} =
      [:bandit, :request]
      |> :telemetry.list_handlers()
      |> Enum.find(&(&1.id == handler_id))

    :ok = :telemetry.detach(handler_id)

    %{config: config}
  end

  describe "setup/0" do
    test "replaces the OpentelemetryBandit handler on the running node" do
      ids = [:bandit, :request] |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      assert {OtelBandit, :otel_bandit} in ids
      refute {OpentelemetryBandit, :otel_bandit} in ids
    end

    test "keeps the handler attached when the client socket is already gone" do
      meta = %{conn: conn(ClosedSocketAdapter)}

      log = capture_log(fn -> :telemetry.execute([:bandit, :request, :start], %{}, meta) end)

      ids = [:bandit, :request] |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      # capture_log/1 collects the whole node, so match the report :telemetry
      # writes when it drops a handler rather than assert on an empty string.
      refute log =~ "has been detached"
      assert {OtelBandit, :otel_bandit} in ids
    end
  end

  describe "handle_request/4" do
    test "skips the span when the client socket is already gone", %{config: config} do
      meta = %{conn: conn(ClosedSocketAdapter)}

      assert OtelBandit.handle_request([:bandit, :request, :start], %{}, meta, config) == :ok
    end

    test "lets other handler failures detach the handler", %{config: config} do
      meta = %{conn: conn(BrokenAdapter)}

      assert_raise ArgumentError, fn ->
        OtelBandit.handle_request([:bandit, :request, :start], %{}, meta, config)
      end
    end
  end

  defp conn(adapter) do
    %Plug.Conn{
      adapter: {adapter, :payload},
      host: "app.firezone.dev",
      method: "GET",
      port: 443,
      request_path: "/",
      scheme: :https
    }
  end
end
