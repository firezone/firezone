defmodule Portal.Defender.ErrorHandler do
  @moduledoc """
  Handles Defender device inventory sync errors.

  Classifies errors, formats user-friendly messages, and updates provider state.
  """

  alias Portal.Defender
  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias __MODULE__.Database
  require Logger

  @disable_transient_errors_after_hours 24

  def handle(%Defender.SyncError{error: error}, provider_id) do
    action(classify(error), format(error), provider_id)
  end

  def handle(error, provider_id) do
    action(:transient, format_generic(error), provider_id)
  end

  # Classification

  # Defender allows 100 calls a minute and 1,500 an hour per tenant, and Req has
  # already retried while honouring Retry-After before the response gets here,
  # so an exhausted budget is a busy tenant rather than a misconfigured one.
  defp classify(%Req.Response{status: status}) when status in [408, 429], do: :transient

  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500,
    do: :client_error

  defp classify(%Req.Response{}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient

  # A machine with no id is a Defender anomaly, not a misconfiguration, so it
  # rides out the transient window instead of disabling the provider and telling
  # the admin to re-grant consent they never lost.
  defp classify(:missing_device_id), do: :transient

  defp classify(_unrecognized), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = error), do: SharedErrorHandler.format_transport_error(error)

  # The token endpoint reports a bad secret with the OAuth error shape, so
  # error_description is what separates that from a grant the admin revoked.
  defp format(%Req.Response{status: status, body: body}) when status in [401, 403] do
    case error_description(body) do
      nil ->
        "Access denied. Please verify the Firezone app registration still has admin consent " <>
          "for Machine.Read.All in Microsoft Entra."

      description ->
        "Authentication failed: #{truncate(description)}"
    end
  end

  # An onboarded tenant with no machines still answers 200 with an empty list,
  # so a 404 means the tenant has never used Defender for Endpoint.
  defp format(%Req.Response{status: 404}) do
    "No devices were found. Please check that Microsoft Defender for Endpoint is set up in " <>
      "this tenant."
  end

  defp format(%Req.Response{status: status, body: %{"error" => error}}) when is_map(error) do
    [
      "HTTP #{status}",
      if(code = Map.get(error, "code"), do: "Code: #{code}"),
      Map.get(error, "message")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" - ")
    |> truncate()
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    truncate("HTTP #{status} - #{body}")
  end

  defp format(%Req.Response{status: status}),
    do: "Microsoft Defender for Endpoint returned HTTP #{status}"

  defp format(:missing_device_id),
    do: "Microsoft Defender for Endpoint returned a device without an ID."

  defp format(error), do: format_generic(error)

  defp error_description(%{"error_description" => description}) when is_binary(description),
    do: description

  defp error_description(_), do: nil

  defp truncate(message) when byte_size(message) > 500 do
    String.slice(message, 0, 500) <> "..."
  end

  defp truncate(message), do: message

  defp format_generic(error) when is_exception(error), do: Exception.message(error)
  defp format_generic(error), do: inspect(error)

  # Action

  defp action(type, message, provider_id) do
    case Database.get_provider(provider_id) do
      nil ->
        Logger.info("Defender provider not found, skipping error update",
          posture_provider_id: provider_id
        )

        :ok

      provider ->
        update_provider(provider, type, message, DateTime.utc_now())
    end
  end

  defp update_provider(provider, :client_error, message, now) do
    Database.update_provider(
      provider,
      Map.merge(%{"errored_at" => now, "error_message" => message}, disable_attrs())
    )
  end

  # A single failed run should not take the provider down, so transient
  # errors only disable it once they have persisted for a full day. Keeping the
  # first errored_at is what makes that window measurable.
  defp update_provider(provider, :transient, message, now) do
    errored_at = provider.errored_at || now
    updates = %{"errored_at" => errored_at, "error_message" => message}

    updates =
      if DateTime.diff(now, errored_at, :hour) >= @disable_transient_errors_after_hours do
        Map.merge(updates, disable_attrs())
      else
        updates
      end

    Database.update_provider(provider, updates)
  end

  defp disable_attrs,
    do: %{"is_disabled" => true, "disabled_reason" => "Sync error", "is_verified" => false}

  defmodule Database do
    @moduledoc false

    import Ecto.Query
    alias Portal.{Defender, Safe}

    def get_provider(provider_id) do
      from(p in Defender.PostureProvider, where: p.id == ^provider_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_provider(provider, attrs) do
      {:ok, _provider} =
        provider
        |> Ecto.Changeset.cast(attrs, [
          :errored_at,
          :error_message,
          :is_disabled,
          :disabled_reason,
          :is_verified
        ])
        |> Safe.unscoped()
        |> Safe.update()

      :ok
    end
  end
end
