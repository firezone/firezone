defmodule Portal.Telemetry.Sentry do
  @ignored_message_patterns [
    # This happens when libcluster loses connection to a node, which is normal during deploys.
    # We have threshold-based error logging in Portal.Cluster.GoogleComputeLabelsStrategy to report those.
    "Node ~p not responding **~n** Removing (timedout) connection",
    "[libcluster:default] unable to connect to"
  ]

  def before_send(%{original_exception: %{skip_sentry: skip_sentry}}) when skip_sentry do
    nil
  end

  # These occur under normal operation whenever a particular account or resource can't be found in the Database.
  def before_send(%{original_exception: %Ecto.NoResultsError{}}) do
    nil
  end

  # These are expected from bots/malicious actors sending invalid CSRF tokens.
  def before_send(%{original_exception: %Plug.CSRFProtection.InvalidCSRFTokenError{}}) do
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
