defmodule Portal.Entra.ErrorFormatter do
  @moduledoc """
  Entra-specific error formatting for directory sync.

  Handles Microsoft Graph API errors and provides user-friendly messages
  with guidance on how to resolve common issues like permission errors.
  """

  @behaviour Portal.DirectorySync.ErrorFormatter

  alias Portal.DirectorySync.ErrorFormatter

  @impl true
  def classify_and_format(context) do
    case classify(context) do
      {:client_error, ctx} -> {:client_error, format(ctx)}
      {:transient, ctx} -> {:transient, format(ctx)}
    end
  end

  @impl true
  def format_generic_error(error) when is_exception(error) do
    Exception.message(error)
  end

  def format_generic_error(error) do
    inspect(error)
  end

  # Classification - determines error type

  # HTTP 4xx -> client_error (disable immediately)
  defp classify(%Req.Response{status: status} = resp) when status >= 400 and status < 500 do
    {:client_error, resp}
  end

  # HTTP 5xx -> transient
  defp classify(%Req.Response{} = resp) do
    {:transient, resp}
  end

  # Batch API errors (from batch_get_users) - 4xx -> client_error
  defp classify({:batch_all_failed, status, body}) when status >= 400 and status < 500 do
    {:client_error, %Req.Response{status: status, body: body}}
  end

  # Batch API errors - 5xx -> transient
  defp classify({:batch_all_failed, status, body}) do
    {:transient, %Req.Response{status: status, body: body}}
  end

  # Batch request failed errors - 4xx -> client_error
  defp classify({:batch_request_failed, status, body}) when status >= 400 and status < 500 do
    {:client_error, %Req.Response{status: status, body: body}}
  end

  # Batch request failed errors - 5xx -> transient
  defp classify({:batch_request_failed, status, body}) do
    {:transient, %Req.Response{status: status, body: body}}
  end

  # Network errors -> transient
  defp classify(%Req.TransportError{} = err) do
    {:transient, err}
  end

  # String contexts with special prefixes -> client_error
  defp classify("validation: " <> _ = msg), do: {:client_error, msg}
  defp classify("scopes: " <> _ = msg), do: {:client_error, msg}
  defp classify("circuit_breaker: " <> _ = msg), do: {:client_error, msg}
  defp classify("consent_revoked: " <> _ = msg), do: {:client_error, msg}

  # nil context -> transient with generic message
  defp classify(nil), do: {:transient, nil}

  # Other string contexts -> transient
  defp classify(msg) when is_binary(msg), do: {:transient, msg}

  # Formatting - converts context to user-friendly message

  # Transport errors
  defp format(%Req.TransportError{} = err) do
    ErrorFormatter.format_transport_error(err)
  end

  # Permission errors (403) with helpful guidance
  defp format(%Req.Response{status: 403, body: %{"error" => error_obj}}) do
    code = Map.get(error_obj, "code")

    base_message =
      case code do
        "Authorization_RequestDenied" ->
          "Insufficient permissions"

        "Forbidden" ->
          "Access forbidden"

        _ ->
          "Permission denied"
      end

    "#{base_message}. Please verify the Firezone Directory Sync app has the required permissions " <>
      "(Directory.Read.All, User.Read.All, and Application.Read.All) in Microsoft Entra and re-grant admin consent."
  end

  # Authentication errors (401) with helpful guidance
  defp format(%Req.Response{status: 401, body: %{"error" => _error_obj}}) do
    "Authentication failed. The app credentials may have expired or been revoked. " <>
      "Please re-grant admin consent in Microsoft Entra."
  end

  # Generic error response with error object
  defp format(%Req.Response{status: status, body: %{"error" => error_obj}}) do
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

  # 403 without error object
  defp format(%Req.Response{status: 403}) do
    "Permission denied. Please verify the Firezone Directory Sync app has the required permissions " <>
      "in Microsoft Entra and re-grant admin consent."
  end

  # 401 without error object
  defp format(%Req.Response{status: 401}) do
    "Authentication failed. Please re-grant admin consent in Microsoft Entra."
  end

  # Response with binary body
  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  # Generic response
  defp format(%Req.Response{status: status}) do
    "Entra API returned HTTP #{status}"
  end

  # nil context
  defp format(nil), do: "Unknown error occurred"

  # String context (pass through)
  defp format(msg) when is_binary(msg), do: msg
end
