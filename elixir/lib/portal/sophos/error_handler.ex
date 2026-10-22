defmodule Portal.Sophos.ErrorHandler do
  @moduledoc "Handles Sophos device inventory sync errors."

  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias Portal.Sophos
  alias __MODULE__.Database
  require Logger

  @disable_transient_errors_after_hours 24

  @doc "Returns `:disabled` when this error disables the provider, or `:ok` otherwise."
  def handle(%Sophos.SyncError{error: error}, provider_id) do
    action(classify(error), format(error), provider_id)
  end

  def handle(error, provider_id) do
    action(:transient, format_generic(error), provider_id)
  end

  defp classify(%Req.Response{status: status}) when status in [408, 429], do: :transient

  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500,
    do: :client_error

  defp classify(%Req.Response{}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient
  defp classify(:unsupported_credentials), do: :client_error
  defp classify(_unrecognized), do: :transient

  defp format(%Req.TransportError{} = error), do: SharedErrorHandler.format_transport_error(error)

  defp format(%Req.Response{status: status}) when status in [401, 403] do
    "Sophos denied access. Verify that the API credentials are still valid and can read endpoints."
  end

  # Sophos errors carry an `error` code and sometimes a readable `message`.
  defp format(%Req.Response{status: status, body: %{"message" => message}}) when is_binary(message) do
    truncate("HTTP #{status} - #{message}")
  end

  defp format(%Req.Response{status: status, body: %{"error" => error}}) when is_binary(error) do
    truncate("HTTP #{status} - #{error}")
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) and body != "" do
    truncate("HTTP #{status} - #{body}")
  end

  defp format(%Req.Response{status: status}), do: "Sophos returned HTTP #{status}"

  defp format(:unsupported_credentials),
    do: "The Sophos API credentials do not belong to a single tenant."

  defp format(error), do: format_generic(error)

  defp truncate(message) when byte_size(message) > 500,
    do: String.slice(message, 0, 500) <> "..."

  defp truncate(message), do: message

  defp format_generic(error) when is_exception(error), do: Exception.message(error)
  defp format_generic(error), do: inspect(error)

  defp action(type, message, provider_id) do
    case Database.get_provider(provider_id) do
      nil ->
        Logger.info("Sophos provider not found, skipping error update",
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
    import Ecto.Query
    alias Portal.{Safe, Sophos}

    def get_provider(provider_id) do
      from(p in Sophos.PostureProvider, where: p.id == ^provider_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_provider(provider, attrs) do
      {:ok, updated_provider} =
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

      if updated_provider.is_disabled and not provider.is_disabled do
        :disabled
      else
        :ok
      end
    end
  end
end
