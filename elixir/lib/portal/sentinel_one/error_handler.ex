defmodule Portal.SentinelOne.ErrorHandler do
  @moduledoc "Handles SentinelOne device inventory sync errors."

  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias Portal.SentinelOne
  alias __MODULE__.Database
  require Logger

  @disable_transient_errors_after_hours 24

  def handle(%SentinelOne.SyncError{error: error}, provider_id) do
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
  defp classify(:missing_agent_uuid), do: :transient
  defp classify(_unrecognized), do: :transient

  defp format(%Req.TransportError{} = error), do: SharedErrorHandler.format_transport_error(error)

  defp format(%Req.Response{status: status, body: %{"errors" => errors}})
       when is_list(errors) and errors != [] do
    details =
      Enum.map_join(errors, "; ", fn
        %{"detail" => detail} when is_binary(detail) -> detail
        %{"title" => title} when is_binary(title) -> title
        error -> inspect(error)
      end)

    truncate("HTTP #{status} - #{details}")
  end

  defp format(%Req.Response{status: status}) when status in [401, 403] do
    "SentinelOne denied access. Verify that the API token is valid and can view endpoints."
  end

  defp format(%Req.Response{status: 404}) do
    "No SentinelOne Management Console answered at this URL."
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    truncate("HTTP #{status} - #{body}")
  end

  defp format(%Req.Response{status: status}), do: "SentinelOne returned HTTP #{status}"

  defp format(:missing_agent_uuid),
    do: "SentinelOne returned an endpoint without its universally unique UUID."
  defp format(error), do: format_generic(error)

  defp truncate(message) when byte_size(message) > 500,
    do: String.slice(message, 0, 500) <> "..."

  defp truncate(message), do: message

  defp format_generic(error) when is_exception(error), do: Exception.message(error)
  defp format_generic(error), do: inspect(error)

  defp action(type, message, provider_id) do
    case Database.get_provider(provider_id) do
      nil ->
        Logger.info("SentinelOne provider not found, skipping error update",
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
    alias Portal.{Safe, SentinelOne}

    def get_provider(provider_id) do
      from(p in SentinelOne.PostureProvider, where: p.id == ^provider_id)
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
