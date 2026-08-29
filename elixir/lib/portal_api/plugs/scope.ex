defmodule PortalAPI.Plugs.Scope do
  @moduledoc """
  Enforces the scopes carried by the request's credential.

  Runs once per request, against the entity the matched controller operates on.
  Scoping every data access instead would make a credential's required scopes
  depend on which lookups a changeset happens to perform - creating a policy
  reads a group and a resource on the way - so the contract would be set by
  implementation detail rather than by the operation the caller asked for.

  Fails closed. A controller behind this pipeline with no entity mapped is
  refused rather than allowed, so adding a route without deciding what it is
  scoped by cannot quietly widen every existing credential.
  """

  import Plug.Conn

  alias Portal.Scope
  alias PortalAPI.Scopes

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{subject: subject}} = conn, _opts) do
    with {:ok, controller} <- matched_controller(conn),
         {:ok, entity} <- Scopes.entity_for(controller),
         :ok <- Scope.permit(entity, method(conn), subject) do
      conn
    else
      :error ->
        forbid(conn, "This operation is not available to a scoped credential.")

      {:error, {:unauthorized, required_scope: required}} ->
        forbid(conn, "This request requires the #{required} scope.")
    end
  end

  def call(conn, _opts), do: conn

  # The router only records the controller when it dispatches, which is after
  # this pipeline has run, so the route is matched again here to learn it.
  defp matched_controller(conn) do
    case Phoenix.Router.route_info(
           PortalAPI.Router,
           conn.method,
           "/" <> Enum.join(conn.path_info, "/"),
           conn.host
         ) do
      %{plug: controller} -> {:ok, controller}
      :error -> :error
    end
  end

  defp method(%Plug.Conn{method: method}) when method in ["GET", "HEAD"], do: :get
  defp method(%Plug.Conn{}), do: :write

  defp forbid(conn, detail) do
    conn
    |> PortalAPI.ProblemDetails.send(403, detail)
    |> halt()
  end
end
