defmodule Domain.Telemetry.Sentry do
  def before_send(%{original_exception: %{skip_sentry: skip_sentry}}) when skip_sentry do
    nil
  end

  def before_send(event) do
    if String.contains?(
         event.message,
         "Node ~p not responding **~n** Removing (timedout) connection"
       ) do
      # This happens when libcluster loses connection to a node, which is normal during deploys.
      # We have threshold-based error logging in Domain.Cluster.GoogleComputeLabelsStrategy to report those.
      nil
    else
      event
    end
  end
end
