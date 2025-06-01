defmodule Domain.Telemetry.Sentry do
  # These happen when libcluster loses connection to a node, which is normal during deploys.
  # We have threshold-based error logging in Domain.Cluster.GoogleComputeLabelsStrategy to report those.
  @silenced_messages [
    "Connection attempt from node ~w rejected. Invalid challenge reply.",
    "Node ~p not responding **~n** Removing (timedout) connection"
  ]

  def before_send(%{original_exception: %{skip_sentry: skip_sentry}}) when skip_sentry do
    nil
  end

  def before_send(event) do
    if Enum.any?(@silenced_messages, &String.contains?(event.message, &1)) do
      nil
    else
      event
    end
  end
end
