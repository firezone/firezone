defmodule Portal.DirectorySync.ErrorHandler do
  @moduledoc """
  Handles errors from directory sync Oban jobs (Entra, Google, Okta).

  This module is responsible for:
  - Extracting meaningful error messages from exceptions
  - Updating directory state based on error type
  - Disabling directories on persistent errors

  Error handling strategy:
  - 4xx HTTP errors: Disable directory immediately (user action required)
  - 5xx HTTP errors: Record error, disable after 24 hours (transient)
  - Network/transport errors: Treat as transient (5xx behavior)
  - Validation errors: Disable directory immediately (bad data in IdP)
  - Missing scopes: Disable directory immediately (user action required)
  - Circuit breaker: Disable directory immediately (user action required)
  - Other errors: Treat as transient (5xx behavior)
  """

  alias __MODULE__.Database
  alias Portal.DirectorySync.SyncError.Context
  require Logger

  @doc """
  Handle an error from a directory sync job.

  Extracts the directory_id from job args, delegates to provider-specific handling,
  and returns extra context for Sentry reporting.
  """
  def handle_error(%{reason: reason, job: job}) do
    directory_id = job.args["directory_id"]

    case job.worker do
      "Portal.Entra.Sync" -> handle_entra_error(reason, directory_id)
      "Portal.Google.Sync" -> handle_google_error(reason, directory_id)
      "Portal.Okta.Sync" -> handle_okta_error(reason, directory_id)
      _ -> :ok
    end

    build_sentry_context(reason, job)
  end

  # Entra error handling

  defp handle_entra_error(%Portal.Entra.SyncError{context: context}, directory_id) do
    {error_type, message} = classify_error(context, &format_entra_error/1)
    update_directory(:entra, directory_id, error_type, message)
  end

  defp handle_entra_error(error, directory_id) do
    message = format_generic_error(error)
    update_directory(:entra, directory_id, :transient, message)
  end

  # Google error handling

  defp handle_google_error(%Portal.Google.SyncError{context: context}, directory_id) do
    {error_type, message} = classify_error(context, &format_google_error/1)
    update_directory(:google, directory_id, error_type, message)
  end

  defp handle_google_error(error, directory_id) do
    message = format_generic_error(error)
    update_directory(:google, directory_id, :transient, message)
  end

  # Okta error handling

  defp handle_okta_error(%Portal.Okta.SyncError{context: context}, directory_id) do
    {error_type, message} = classify_error(context, &format_okta_error/1)
    update_directory(:okta, directory_id, error_type, message)
  end

  defp handle_okta_error(error, directory_id) do
    message = format_generic_error(error)
    update_directory(:okta, directory_id, :transient, message)
  end

  # Error classification - pattern matches on the Context struct

  # HTTP 4xx -> client_error (disable immediately)
  defp classify_error(%Context{type: :http, data: %{status: status}} = ctx, format_fn)
       when status >= 400 and status < 500 do
    {:client_error, format_fn.(ctx)}
  end

  # HTTP 5xx -> transient
  defp classify_error(%Context{type: :http} = ctx, format_fn) do
    {:transient, format_fn.(ctx)}
  end

  # Network errors -> transient
  defp classify_error(%Context{type: :network} = ctx, _format_fn) do
    {:transient, format_network_error(ctx)}
  end

  # Validation errors -> client_error (bad data in IdP)
  defp classify_error(%Context{type: :validation} = ctx, _format_fn) do
    {:client_error, format_validation_error(ctx)}
  end

  # Missing scopes -> client_error
  defp classify_error(%Context{type: :scopes} = ctx, _format_fn) do
    {:client_error, format_scopes_error(ctx)}
  end

  # Circuit breaker -> client_error
  defp classify_error(%Context{type: :circuit_breaker} = ctx, _format_fn) do
    {:client_error, format_circuit_breaker_error(ctx)}
  end

  # nil context -> transient with generic message
  defp classify_error(nil, _format_fn) do
    {:transient, "Unknown error occurred"}
  end

  # Error formatting - Provider-specific HTTP error formatting

  defp format_entra_error(%Context{type: :http, data: %{status: status, body: %{"error" => error_obj}}}) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")
    inner_code = get_in(error_obj, ["innerError", "code"])

    parts =
      [
        "HTTP #{status}",
        if(code, do: "Code: #{code}"),
        if(inner_code && inner_code != code, do: "Inner Code: #{inner_code}"),
        if(message, do: message)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  defp format_entra_error(%Context{type: :http, data: %{status: status, body: body}}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp format_entra_error(%Context{type: :http, data: %{status: status}}) do
    "Entra API returned HTTP #{status}"
  end

  defp format_entra_error(%Context{} = ctx) do
    format_context_error(ctx)
  end

  defp format_google_error(%Context{type: :http, data: %{status: status, body: %{"error" => error_obj}}})
       when is_map(error_obj) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")

    reason =
      case Map.get(error_obj, "errors") do
        [%{"reason" => r} | _] -> r
        _ -> nil
      end

    parts =
      [
        "HTTP #{status}",
        if(code && code != status, do: "Code: #{code}"),
        if(reason, do: "Reason: #{reason}"),
        if(message, do: message)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  defp format_google_error(%Context{type: :http, data: %{status: status, body: body}}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp format_google_error(%Context{type: :http, data: %{status: status}}) do
    "Google API returned HTTP #{status}"
  end

  defp format_google_error(%Context{} = ctx) do
    format_context_error(ctx)
  end

  defp format_okta_error(%Context{type: :http, data: %{status: status, body: body}}) when is_map(body) do
    Portal.Okta.ErrorCodes.format_error(status, body)
  end

  defp format_okta_error(%Context{type: :http, data: %{status: status, body: body}}) when is_binary(body) do
    Portal.Okta.ErrorCodes.format_error(status, body)
  end

  defp format_okta_error(%Context{type: :http, data: %{status: status}}) do
    Portal.Okta.ErrorCodes.format_error(status, nil)
  end

  defp format_okta_error(%Context{} = ctx) do
    format_context_error(ctx)
  end

  # Generic Context formatting for non-HTTP contexts
  defp format_context_error(%Context{type: :network} = ctx), do: format_network_error(ctx)
  defp format_context_error(%Context{type: :validation} = ctx), do: format_validation_error(ctx)
  defp format_context_error(%Context{type: :scopes} = ctx), do: format_scopes_error(ctx)
  defp format_context_error(%Context{type: :circuit_breaker} = ctx), do: format_circuit_breaker_error(ctx)

  @doc """
  Format network/transport errors into user-friendly messages.

  Handles DNS failures, timeouts, TLS errors, and other network issues.
  """
  @spec format_transport_error(Exception.t()) :: String.t()
  def format_transport_error(%Req.TransportError{reason: reason}) do
    format_transport_reason(reason)
  end

  defp format_network_error(%Context{type: :network, data: %{reason: reason}}) do
    format_transport_reason(reason)
  end

  defp format_transport_reason(reason) do
    case reason do
      :nxdomain ->
        "DNS lookup failed."

      :timeout ->
        "Connection timed out."

      :connect_timeout ->
        "Connection timed out."

      :econnrefused ->
        "Connection refused."

      :closed ->
        "Connection closed unexpectedly."

      {:tls_alert, {alert_type, _}} ->
        "TLS error (#{alert_type})."

      :ehostunreach ->
        "Host is unreachable."

      :enetunreach ->
        "Network is unreachable."

      _ ->
        "Network error: #{inspect(reason)}"
    end
  end

  defp format_validation_error(%Context{type: :validation, data: data}) do
    entity = Map.get(data, :entity) || Map.get(data, :entity_type)
    id = Map.get(data, :id) || Map.get(data, :entity_id)
    field = Map.get(data, :field) || Map.get(data, :missing_field)

    entity_desc =
      if id do
        "#{entity} '#{id}'"
      else
        to_string(entity)
      end

    "#{String.capitalize(entity_desc)} missing required '#{field}' field."
  end

  defp format_scopes_error(%Context{type: :scopes, data: %{missing: missing_scopes}}) do
    "Access token missing required scopes: #{Enum.join(missing_scopes, ", ")}. " <>
      "Grant the following scopes to your application: #{Enum.join(missing_scopes, ", ")}"
  end

  defp format_circuit_breaker_error(%Context{type: :circuit_breaker, data: %{resource: resource}}) do
    "Sync would delete all #{resource}. " <>
      "This may indicate your application was misconfigured. " <>
      "Please verify your configuration and re-verify the directory."
  end

  defp format_generic_error(error) when is_exception(error) do
    Exception.message(error)
  end

  defp format_generic_error(error) do
    inspect(error)
  end

  # Directory updates

  defp update_directory(provider, directory_id, error_type, error_message) do
    now = DateTime.utc_now()

    case Database.get_directory(provider, directory_id) do
      nil ->
        Logger.info("Directory not found, skipping error update",
          provider: provider,
          directory_id: directory_id
        )

        :ok

      directory ->
        do_update_directory(directory, error_type, error_message, now)
    end
  end

  defp do_update_directory(directory, :client_error, error_message, now) do
    # 4xx errors - disable immediately, user action required
    Database.update_directory(directory, %{
      "errored_at" => now,
      "error_message" => error_message,
      "is_disabled" => true,
      "disabled_reason" => "Sync error",
      "is_verified" => false
    })
  end

  defp do_update_directory(directory, :transient, error_message, now) do
    # Transient errors - record error, disable after 24 hours
    errored_at = directory.errored_at || now
    hours_since_error = DateTime.diff(now, errored_at, :hour)
    should_disable = hours_since_error >= 24

    updates = %{
      "errored_at" => errored_at,
      "error_message" => error_message
    }

    updates =
      if should_disable do
        Map.merge(updates, %{
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })
      else
        updates
      end

    Database.update_directory(directory, updates)
  end

  # Sentry context building

  defp build_sentry_context(
         %{
           __struct__: struct,
           reason: reason,
           context: context,
           directory_id: directory_id,
           step: step
         },
         job
       )
       when struct in [Portal.Entra.SyncError, Portal.Google.SyncError, Portal.Okta.SyncError] do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
    |> Map.put(:directory_id, directory_id)
    |> Map.put(:step, step)
    |> Map.put(:reason, reason)
    |> Map.put(:context, format_context(context))
  end

  defp build_sentry_context(_reason, job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end

  defp format_context(%Context{} = ctx) do
    ctx
    |> Map.from_struct()
    |> Map.put(:__type__, "Context")
  end

  defp format_context(%Req.Response{status: status, body: body}) when is_map(body) do
    %{type: "Req.Response", status: status, body: body}
  end

  defp format_context(%Req.Response{status: status, body: body}) when is_binary(body) do
    %{type: "Req.Response", status: status, body: String.slice(body, 0, 500)}
  end

  defp format_context(%Req.Response{status: status}) do
    %{type: "Req.Response", status: status}
  end

  defp format_context(%Req.TransportError{reason: reason}) do
    %{type: "Req.TransportError", reason: inspect(reason)}
  end

  defp format_context(context) when is_exception(context) do
    %{type: inspect(context.__struct__), message: Exception.message(context)}
  end

  defp format_context(nil), do: nil

  defp format_context(context) do
    inspect(context)
  end

  defmodule Database do
    @moduledoc false

    import Ecto.Query
    alias Portal.{Safe, Entra, Google, Okta}

    def get_directory(:entra, directory_id) do
      from(d in Entra.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_directory(:google, directory_id) do
      from(d in Google.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_directory(:okta, directory_id) do
      from(d in Okta.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(directory, attrs) do
      changeset =
        Ecto.Changeset.cast(directory, attrs, [
          :errored_at,
          :error_message,
          :is_disabled,
          :disabled_reason,
          :is_verified
        ])

      {:ok, _directory} = changeset |> Safe.unscoped() |> Safe.update()
    end
  end
end
