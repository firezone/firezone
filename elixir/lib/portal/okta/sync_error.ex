defmodule Portal.Okta.SyncError do
  @moduledoc """
  Exception and error handling for Okta directory sync.

  This module:
  - Defines the SyncError exception raised during sync
  - Handles errors from Oban telemetry via handle_error/1
  - Classifies errors as client_error (disable) or transient (retry)
  - Formats error messages for users and Sentry
  """

  alias Portal.DirectorySync.CommonError

  import Ecto.Query

  require Logger

  defmodule Database do
    alias Portal.Safe

    def get_directory(directory_id) do
      from(d in Portal.Okta.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(changeset) do
      changeset |> Safe.unscoped() |> Safe.update()
    end
  end

  # Error code → resolution mapping (inlined from ErrorCodes)
  @error_codes %{
    # Authentication (401)
    "E0000004" =>
      "Verify your Okta API credentials. Check that the Client ID is correct and the private key matches the public key configured in Okta.",
    "E0000011" =>
      "Invalid token. Please ensure your Client ID and private key are correct and the JWT is properly signed.",
    "E0000061" => "Access denied. The client application is not authorized to use this API.",
    "E0000015" => "This feature requires a higher Okta plan. Contact your Okta administrator.",

    # Authorization (403)
    "E0000006" =>
      "Access denied. You do not have permission to perform this action. Ensure the API service app has the required scopes: okta.users.read, okta.groups.read, okta.apps.read",
    "E0000022" =>
      "API access denied. The feature may not be available for your Okta organization.",

    # Validation (400)
    "E0000001" => "API validation failed. Check your request parameters.",
    "E0000003" => "The request body was invalid. Please check your configuration.",
    "E0000021" =>
      "Bad request to Okta API. Please verify your Okta domain and API configuration.",

    # Rate Limiting (429)
    "E0000047" => "The Okta API rate limit has been exceeded. Syncs will automatically retry.",

    # Not Found (404)
    "E0000007" => "Resource not found. Please verify your Okta domain is correct.",
    "E0000008" =>
      "The API endpoint was not found. Verify your Okta domain (e.g., your-org.okta.com).",
    "E0000048" =>
      "The requested entity does not exist in Okta. It may have been recently deleted.",

    # Server Errors (500+)
    "E0000009" =>
      "Okta experienced an internal error. Syncs will automatically retry. Check status.okta.com if this persists.",
    "E0000010" =>
      "Okta is in read-only maintenance mode. Syncs will automatically retry once maintenance completes."
  }

  # Special handling for invalid_client which has different messages based on status
  @invalid_client_messages %{
    400 => "Invalid client application. Please verify your Client ID is correct.",
    401 =>
      "Client authentication failed. Please verify your Client ID and ensure the public key is registered in Okta."
  }

  @empty_resource_messages %{
    apps:
      "No apps found in your Okta account. Please ensure the OIDC app is created and that the API service integration app has the okta.apps.read scope granted.",
    users:
      "No users found in your Okta account. Please ensure users are assigned to the OIDC app and the API service integration app has the okta.users.read scope granted.",
    groups:
      "No groups found in your Okta account. Please ensure groups are assigned to the OIDC app and the API service integration app has the okta.groups.read scope granted."
  }

  # Exception definition
  defexception [:message, :error, :directory_id, :step]

  @impl true
  def exception(opts) do
    error = Keyword.fetch!(opts, :error)
    directory_id = Keyword.fetch!(opts, :directory_id)
    step = Keyword.fetch!(opts, :step)

    message = build_message(error, directory_id, step)

    %__MODULE__{
      message: message,
      error: error,
      directory_id: directory_id,
      step: step
    }
  end

  defp build_message(%Req.Response{status: status, body: body}, directory_id, step)
       when is_integer(status) do
    "Okta sync failed for directory #{directory_id} at #{step}: HTTP #{status} - #{inspect(body)}"
  end

  defp build_message(%Req.TransportError{} = error, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{Exception.message(error)}"
  end

  defp build_message({:validation, msg}, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{msg}"
  end

  defp build_message({:scopes, msg}, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: missing scopes: #{msg}"
  end

  defp build_message({:circuit_breaker, msg}, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: circuit breaker: #{msg}"
  end

  defp build_message({:db_error, error}, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: database error: #{inspect(error)}"
  end

  defp build_message(%{__exception__: true} = exception, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{Exception.message(exception)}"
  end

  defp build_message(error, directory_id, step) when is_binary(error) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{error}"
  end

  defp build_message(error, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{inspect(error)}"
  end

  # Public API for Oban telemetry reporter

  @doc """
  Handle an error from an Okta sync job.

  Called by the Oban telemetry reporter. Classifies the error,
  formats it for display, updates the directory state, and returns
  Sentry context.
  """
  @spec handle_error(map()) :: map()
  def handle_error(%{reason: reason, job: job}) do
    directory_id = job.args["directory_id"]

    case reason do
      %__MODULE__{error: error} = sync_error ->
        {error_type, message} = classify_and_format(error)
        update_directory(directory_id, error_type, message)
        build_sentry_context(sync_error, job)

      error ->
        message = format_generic_error(error)
        update_directory(directory_id, :transient, message)
        build_default_sentry_context(job)
    end
  end

  # Public API for LiveView verification

  @doc """
  Format an error for display during verification.

  Used by the DirectorySync LiveView for Okta verification errors.
  """
  @spec format_for_status(integer(), map() | binary() | nil) :: String.t()
  def format_for_status(status, body) when is_map(body) and map_size(body) > 0 do
    error_code = body["errorCode"] || body["error"]
    error_summary = body["errorSummary"] || body["error_description"]

    cond do
      resolution = get_resolution(error_code, status) ->
        resolution

      error_summary && is_nil(error_code) ->
        "#{summary_prefix(status)}: #{error_summary}"

      error_code && error_summary ->
        "#{summary_prefix(status)} (#{error_code}): #{error_summary}"

      error_summary ->
        "#{summary_prefix(status)}: #{error_summary}"

      error_code ->
        "#{status_label(status)} (#{error_code}). #{default_resolution(status)}"

      true ->
        fallback_message(status)
    end
  end

  def format_for_status(status, body) when is_binary(body) and byte_size(body) > 0 do
    "HTTP #{status} - #{body}"
  end

  def format_for_status(status, _body) do
    fallback_message(status)
  end

  @doc """
  Get message for empty resource errors during verification.
  """
  @spec empty_resource_message(:apps | :users | :groups) :: String.t()
  def empty_resource_message(resource) when resource in [:apps, :users, :groups] do
    Map.fetch!(@empty_resource_messages, resource)
  end

  # Internal classification and formatting

  defp classify_and_format(error) do
    error_type = classify(error)
    message = format(error)
    {error_type, message}
  end

  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500,
    do: :client_error

  defp classify(%Req.Response{}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient
  defp classify({:validation, _}), do: :client_error
  defp classify({:scopes, _}), do: :client_error
  defp classify({:circuit_breaker, _}), do: :client_error
  defp classify({:db_error, _}), do: :transient
  defp classify(nil), do: :transient
  defp classify(_), do: :transient

  defp format(%Req.Response{status: status, body: body}) when is_map(body) do
    format_for_status(status, body)
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    format_for_status(status, body)
  end

  defp format(%Req.Response{status: status}) do
    format_for_status(status, nil)
  end

  defp format(%Req.TransportError{} = error), do: CommonError.format(error)
  defp format({:validation, msg}), do: msg
  defp format({:scopes, msg}), do: "Missing required scopes: #{msg}"
  defp format({:circuit_breaker, msg}), do: msg
  defp format({:db_error, error}), do: CommonError.format(error)
  defp format(nil), do: "Unknown error occurred"
  defp format(msg) when is_binary(msg), do: msg
  defp format(error), do: CommonError.format(error)

  defp format_generic_error(error) when is_exception(error), do: Exception.message(error)
  defp format_generic_error(error), do: inspect(error)

  # Resolution helpers

  defp get_resolution(nil, _status), do: nil

  defp get_resolution("invalid_client", status) do
    Map.get(@invalid_client_messages, status) ||
      "Client authentication failed. Please verify your Client ID and ensure the public key is registered in Okta."
  end

  defp get_resolution(error_code, _status), do: Map.get(@error_codes, error_code)

  @doc """
  Default resolution based on HTTP status code.
  """
  @spec default_resolution(integer()) :: String.t()
  def default_resolution(status) when status >= 500 do
    "Okta service is currently unavailable. Please try again later or check status.okta.com"
  end

  def default_resolution(429),
    do: "Rate limit exceeded. Syncs will automatically retry."

  def default_resolution(404),
    do: "Please verify your Okta domain (e.g., your-org.okta.com) is correct."

  def default_resolution(403),
    do: "Ensure the application has okta.users.read and okta.groups.read scopes granted."

  def default_resolution(401),
    do: "Please check your Client ID and ensure the public key matches your private key."

  def default_resolution(400),
    do: "Please verify your Okta domain and Client ID."

  def default_resolution(_status),
    do: "Please verify your Okta configuration."

  defp summary_prefix(400), do: "Configuration error"
  defp summary_prefix(401), do: "Authentication failed"
  defp summary_prefix(403), do: "Permission denied"
  defp summary_prefix(404), do: "Not found"
  defp summary_prefix(429), do: "Rate limited"
  defp summary_prefix(_status), do: "Error"

  defp status_label(400), do: "HTTP 400 Bad Request"
  defp status_label(401), do: "HTTP 401 Unauthorized"
  defp status_label(403), do: "HTTP 403 Forbidden"
  defp status_label(404), do: "HTTP 404 Not Found"
  defp status_label(429), do: "HTTP 429 Too Many Requests"
  defp status_label(status) when status >= 500, do: "HTTP #{status} Server Error"
  defp status_label(status), do: "HTTP #{status}"

  defp fallback_message(status) when status >= 500 do
    "Okta service is currently unavailable (HTTP #{status}). Please try again later."
  end

  defp fallback_message(400) do
    "HTTP 400 Bad Request. Please verify your Okta domain and Client ID."
  end

  defp fallback_message(401) do
    "HTTP 401 Unauthorized. Please check your Client ID and ensure the public key matches your private key."
  end

  defp fallback_message(403) do
    "HTTP 403 Forbidden. Ensure the application has okta.users.read and okta.groups.read scopes granted."
  end

  defp fallback_message(404) do
    "HTTP 404 Not Found. Please verify your Okta domain (e.g., your-domain.okta.com) is correct."
  end

  defp fallback_message(status) do
    "Okta API returned HTTP #{status}. #{default_resolution(status)}"
  end

  # Directory updates

  defp update_directory(directory_id, error_type, error_message) do
    now = DateTime.utc_now()

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Directory not found, skipping error update",
          provider: :okta,
          directory_id: directory_id
        )

        :ok

      directory ->
        do_update_directory(directory, error_type, error_message, now)
    end
  end

  defp do_update_directory(directory, :client_error, error_message, now) do
    changeset =
      Ecto.Changeset.cast(
        directory,
        %{
          "errored_at" => now,
          "error_message" => error_message,
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        },
        [:errored_at, :error_message, :is_disabled, :disabled_reason, :is_verified]
      )

    {:ok, _directory} = Database.update_directory(changeset)
  end

  defp do_update_directory(directory, :transient, error_message, now) do
    errored_at = directory.errored_at || now
    hours_since_error = DateTime.diff(now, errored_at, :hour)
    should_disable = hours_since_error >= 24

    attrs = %{
      "errored_at" => errored_at,
      "error_message" => error_message
    }

    attrs =
      if should_disable do
        Map.merge(attrs, %{
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })
      else
        attrs
      end

    changeset =
      Ecto.Changeset.cast(directory, attrs, [
        :errored_at,
        :error_message,
        :is_disabled,
        :disabled_reason,
        :is_verified
      ])

    {:ok, _directory} = Database.update_directory(changeset)
  end

  # Sentry context building

  defp build_sentry_context(
         %__MODULE__{error: error, directory_id: directory_id, step: step},
         job
       ) do
    job
    |> Map.take([:id, :args, :meta, :queue, :worker])
    |> Map.put(:directory_id, directory_id)
    |> Map.put(:step, step)
    |> Map.put(:error, inspect(error))
  end

  defp build_default_sentry_context(job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
