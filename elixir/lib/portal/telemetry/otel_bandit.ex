defmodule Portal.Telemetry.OtelBandit do
  @moduledoc false

  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception]
  ]

  @handler_id {__MODULE__, :otel_bandit}

  def setup do
    :ok = OpentelemetryBandit.setup()

    %{id: id, config: config} =
      [:bandit, :request]
      |> :telemetry.list_handlers()
      |> Enum.find(&match?({OpentelemetryBandit, _handler_id}, &1.id))

    :ok = :telemetry.detach(id)

    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_request/4, config)
  end

  # A client that hangs up mid-request leaves Bandit unable to read the peer address, which
  # raises here. Without this rescue :telemetry detaches the handler and the node stops
  # tracing HTTP requests until it restarts.
  def handle_request(event, measurements, meta, config) do
    OpentelemetryBandit.handle_request(event, measurements, meta, config)
  rescue
    Bandit.TransportError -> :ok
  end
end
