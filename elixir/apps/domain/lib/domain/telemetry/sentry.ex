defmodule Domain.Telemetry.Sentry do
  def before_send(%{original_exception: %{report_to_sentry: report_to_sentry}} = event) do
    if report_to_sentry do
      event
    else
      nil
    end
  end

  def before_send(event) do
    event
  end
end
