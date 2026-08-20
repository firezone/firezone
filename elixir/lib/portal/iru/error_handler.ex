defmodule Portal.Iru.ErrorHandler do
  @moduledoc """
  Handles Iru device inventory sync errors.

  Classifies errors, formats user-friendly messages, and updates provider state.
  """

  alias Portal.Iru
  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias __MODULE__.Database
  require Logger

  @disable_transient_errors_after_hours 24

  def handle(%Iru.SyncError{error: error}, provider_id) do
    action(classify(error), format(error), provider_id)
  end

  def handle(error, provider_id) do
    action(:transient, format_generic(error), provider_id)
  end

  # Classification

  # Iru allows 10,000 requests an hour per customer, and Req has already retried
  # while honouring Retry-After before the response gets here, so an exhausted
  # budget is a busy tenant rather than a misconfigured one.
  defp classify(%Req.Response{status: status}) when status in [408, 429], do: :transient

  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500,
    do: :client_error

  defp classify(%Req.Response{}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient

  # A device with no id is an Iru anomaly, not a misconfiguration, so it rides
  # out the transient window instead of asking the admin to fix a token that
  # works.
  defp classify(:missing_device_id), do: :transient

  defp classify(_unrecognized), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = error), do: SharedErrorHandler.format_transport_error(error)

  defp format(%Req.Response{status: 401}) do
    "Authentication failed. The Iru API token is expired, was revoked, or is not " <>
      "the token for this tenant."
  end

  defp format(%Req.Response{status: 403}) do
    "Access denied. Please give the Iru API token permission to list devices."
  end

  defp format(%Req.Response{status: 404}) do
    "Iru returned HTTP 404. Please check the subdomain and the region of the tenant."
  end

  defp format(%Req.Response{status: status, body: %{"detail" => detail}}) when is_binary(detail) do
    truncate("HTTP #{status} - #{detail}")
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    truncate("HTTP #{status} - #{body}")
  end

  defp format(%Req.Response{status: status}), do: "Iru returned HTTP #{status}"
  defp format(:missing_device_id), do: "Iru returned a device without an ID."
  defp format(error), do: format_generic(error)

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
        Logger.info("Iru provider not found, skipping error update",
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

  # A single failed run should not take the provider down, so transient errors
  # only disable it once they have persisted for a full day. Keeping the first
  # errored_at is what makes that window measurable.
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
    alias Portal.{Iru, Safe}

    def get_provider(provider_id) do
      from(p in Iru.PostureProvider, where: p.id == ^provider_id)
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
