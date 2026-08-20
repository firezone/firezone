defmodule Portal.Intune.ErrorHandler do
  @moduledoc """
  Handles Intune device inventory sync errors.

  Classifies errors, formats user-friendly messages, and updates provider state.
  """

  alias Portal.Intune
  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias __MODULE__.Database
  require Logger

  @disable_transient_errors_after_hours 24

  def handle(%Intune.SyncError{error: error}, provider_id) do
    action(classify(error), format(error), provider_id)
  end

  def handle(error, provider_id) do
    action(:transient, format_generic(error), provider_id)
  end

  # Classification

  # Req has already retried these four times, honouring Retry-After, before the
  # response gets here, so an exhausted throttle is a busy tenant rather than a
  # misconfigured one. Disabling would make a large tenant re-run the admin
  # consent flow to recover from being rate limited.
  defp classify(%Req.Response{status: status}) when status in [408, 429], do: :transient

  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500,
    do: :client_error

  defp classify(%Req.Response{}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient

  # A managedDevice with no id is a Graph anomaly, not a misconfiguration, so it
  # rides out the transient window instead of disabling the provider and
  # telling the admin to re-grant consent they never lost.
  defp classify(:missing_device_id), do: :transient

  defp classify(_unrecognized), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = error), do: SharedErrorHandler.format_transport_error(error)

  # Intune answers a missing-permission call with 401 and code "UnknownError",
  # burying the real reason in an escaped JSON blob, so neither the status nor
  # the Graph error code separates a revoked grant from a bad secret. The token
  # endpoint is the one that reports a bad secret, and it uses the OAuth error
  # shape, so error_description is what tells the two apart.
  defp format(%Req.Response{status: status, body: body}) when status in [401, 403] do
    case error_description(body) do
      nil ->
        "Access denied. Please verify the Firezone app registration still has admin consent " <>
          "for DeviceManagementManagedDevices.Read.All in Microsoft Entra."

      description ->
        "Authentication failed: #{truncate(description)}"
    end
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
    "HTTP #{status} - #{body}"
  end

  defp format(%Req.Response{status: status}), do: "Microsoft Graph returned HTTP #{status}"
  defp format(:missing_device_id), do: "Microsoft Graph returned a device without an ID."
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
        Logger.info("Intune provider not found, skipping error update",
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
    alias Portal.{Intune, Safe}

    def get_provider(provider_id) do
      from(i in Intune.PostureProvider, where: i.id == ^provider_id)
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
