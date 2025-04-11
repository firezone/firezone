defmodule Domain.Telemetry.Sentry do
  def before_send(%{original_exception: %{skip_sentry: skip_sentry}} = event) do
    if skip_sentry do
      nil
    else
      event
    end
  end

  def before_send(event) do
    event
  end
end
