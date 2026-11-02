defmodule Portal.GoogleEndpoint.ErrorHandler do
  @moduledoc "Handles Google Endpoint Management device inventory sync errors."

  alias Portal.{DirectorySync, GoogleEndpoint}
  alias __MODULE__.Database
  require Logger

  @disable_transient_errors_after_hours 24

  # Federation and deployment configuration are Firezone's side of the
  # exchange, so a failure there is never the customer's to fix.
  @federation_stages [:managed_identity, :workload_identity_token_exchange, :service_account_sign_jwt]
  @deployment_errors [:service_account_not_configured, :incomplete_workload_identity_configuration]

  @doc "Returns `:disabled` when this error disables the provider, or `:ok` otherwise."
  def handle(%GoogleEndpoint.SyncError{error: error}, provider_id) do
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
  defp classify(_unrecognized), do: :transient

  defp format(%Req.TransportError{} = error),
    do: DirectorySync.ErrorHandler.format_transport_error(error)

  # The token endpoint answers with an OAuth error code rather than a Google
  # API error object.
  defp format(%Req.Response{body: %{"error" => "unauthorized_client"}}) do
    "Google refused to issue a token. Check that domain-wide delegation for the Firezone " <>
      "client ID still grants #{GoogleEndpoint.APIClient.scope()}."
  end

  defp format(%Req.Response{body: %{"error" => "invalid_grant"} = body}) do
    truncate(
      "Google refused to act as the verifying administrator: " <>
        "#{body["error_description"] || "invalid_grant"}. Verify again with an active administrator."
    )
  end

  defp format(%Req.Response{status: status}) when status in [401, 403] do
    "Google denied access to devices. Check that the verifying administrator can still manage devices."
  end

  defp format(%Req.Response{status: status, body: %{"error" => %{"message" => message}}})
       when is_binary(message) do
    truncate("HTTP #{status} - #{message}")
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) and body != "" do
    truncate("HTTP #{status} - #{body}")
  end

  defp format(%Req.Response{status: status}), do: "Google returned HTTP #{status}"

  defp format({stage, _reason}) when stage in @federation_stages,
    do: "Firezone could not authenticate to Google. This is usually temporary."

  defp format(error) when error in @deployment_errors,
    do: "Google Endpoint Management is not configured for this Firezone deployment."

  defp format(error), do: format_generic(error)

  defp truncate(message) when byte_size(message) > 500,
    do: String.slice(message, 0, 500) <> "..."

  defp truncate(message), do: message

  defp format_generic(error) when is_exception(error), do: Exception.message(error)
  defp format_generic(error), do: inspect(error)

  defp action(type, message, provider_id) do
    case Database.get_provider(provider_id) do
      nil ->
        Logger.info("Google Endpoint provider not found, skipping error update",
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
    alias Portal.{GoogleEndpoint, Safe}

    def get_provider(provider_id) do
      from(p in GoogleEndpoint.PostureProvider, where: p.id == ^provider_id)
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
