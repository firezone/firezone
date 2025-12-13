defmodule Domain.Telemetry.Sentry do
  @ignored_message_patterns [
    # This happens when libcluster loses connection to a node, which is normal during deploys.
    # We have threshold-based error logging in Domain.Cluster.GoogleComputeLabelsStrategy to report those.
    "Node ~p not responding **~n** Removing (timedout) connection",
    "[libcluster:default] unable to connect to",

    # These occur under normal operation whenever a particular account or resource can't be found in the DB.
    "expected at least one result but got none in query"
  ]

  def before_send(%{original_exception: %{skip_sentry: skip_sentry}}) when skip_sentry do
    nil
  end

  def before_send(%{message: %{formatted: formatted_message}} = event)
      when is_binary(formatted_message) do
    if Enum.any?(@ignored_message_patterns, fn p ->
         String.contains?(formatted_message, p)
       end) do
      nil
    else
      event
    end
  end

  def before_send(event), do: event
end
