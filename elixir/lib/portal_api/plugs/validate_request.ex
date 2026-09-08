defmodule PortalAPI.Plugs.ValidateRequest do
  @moduledoc """
  Casts and validates the request against the OpenAPI operation the controller
  action declares, so a request the spec calls invalid never reaches a
  controller.

  Runs as a controller plug, since the operation is only known once the router
  has dispatched. Controllers without operation specs, such as those mounted
  outside the `:api` pipeline, pass through untouched.
  """

  @behaviour Plug

  alias OpenApiSpex.Plug.CastAndValidate

  @impl Plug
  def init(opts) do
    CastAndValidate.init(
      Keyword.merge(
        [render_error: PortalAPI.Plugs.RequestValidationError, replace_params: false],
        opts
      )
    )
  end

  @impl Plug
  def call(%Plug.Conn{private: %{open_api_spex: _, phoenix_controller: controller}} = conn, opts) do
    if function_exported?(controller, :open_api_operation, 1) do
      CastAndValidate.call(conn, opts)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
