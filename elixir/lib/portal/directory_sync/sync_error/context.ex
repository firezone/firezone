defmodule Portal.DirectorySync.SyncError.Context do
  @moduledoc """
  Provides context for directory sync errors.

  Used across all directory sync providers (Okta, Google, Entra) to ensure
  consistent error classification and provide meaningful context for debugging.

  ## Context Types

  - `:http` - HTTP errors from API responses (4xx, 5xx status codes)
  - `:network` - Network/transport errors (DNS failures, timeouts, TLS errors)
  - `:validation` - Validation errors (missing required fields in IdP data)
  - `:scopes` - Missing OAuth scopes
  - `:circuit_breaker` - Circuit breaker threshold exceeded

  ## Usage

      # HTTP errors - use helper
      Context.from_response(response)

      # Network errors - use helper
      Context.from_transport_error(error)

      # Everything else - direct struct creation
      %Context{type: :validation, data: %{entity: :user, id: "user-123", field: :email}}
      %Context{type: :scopes, data: %{missing: ["okta.users.read"]}}
      %Context{type: :circuit_breaker, data: %{resource: :identities}}
  """

  @type context_type :: :http | :network | :validation | :scopes | :circuit_breaker

  @type t :: %__MODULE__{
          type: context_type(),
          data: map()
        }

  defstruct [:type, data: %{}]

  @doc """
  Wrap a Req.Response into a Context.

  Extracts status and body from the response.

  ## Examples

      iex> Context.from_response(%Req.Response{status: 401, body: %{"error" => "unauthorized"}})
      %Context{type: :http, data: %{status: 401, body: %{"error" => "unauthorized"}}}
  """
  @spec from_response(Req.Response.t()) :: t()
  def from_response(%Req.Response{status: status, body: body}) do
    %__MODULE__{type: :http, data: %{status: status, body: body}}
  end

  @doc """
  Wrap a Req.TransportError into a Context.

  Extracts the reason from the transport error.

  ## Examples

      iex> Context.from_transport_error(%Req.TransportError{reason: :timeout})
      %Context{type: :network, data: %{reason: :timeout}}
  """
  @spec from_transport_error(Exception.t()) :: t()
  def from_transport_error(%Req.TransportError{reason: reason}) do
    %__MODULE__{type: :network, data: %{reason: reason}}
  end

  @doc """
  Wrap an API error (Req.Response or Req.TransportError) into a Context.

  Use this when handling errors from API clients that can return either type.

  ## Examples

      iex> Context.from_error(%Req.Response{status: 401, body: %{}})
      %Context{type: :http, data: %{status: 401, body: %{}}}

      iex> Context.from_error(%Req.TransportError{reason: :timeout})
      %Context{type: :network, data: %{reason: :timeout}}
  """
  @spec from_error(Req.Response.t() | Exception.t()) :: t()
  def from_error(%Req.Response{} = resp), do: from_response(resp)
  def from_error(%Req.TransportError{} = err), do: from_transport_error(err)
end
