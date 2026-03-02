defmodule Portal.Telemetry.Sentry do
  @ignored_message_regexes [
    # This happens when libcluster loses connection to a node, which is normal during deploys.
    ~r/Node ~p not responding \*\*~n\*\* Removing \(timedout\) connection/,
    ~r/\[libcluster:default\] unable to connect to/,
    ~r/^'global' at node '.+' disconnected node '.+' in order to prevent overlapping partitions$/
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
    ignored_by_regex? =
      Enum.any?(@ignored_message_regexes, fn regex ->
        Regex.match?(regex, formatted_message)
      end)

    if ignored_by_regex? do
      nil
    else
      event
    end
  end

  def before_send(event), do: event
end
