defmodule Web.Auth do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, opts) do
    verify_condition(conn, opts)
  end

  def verify_condition(conn, :unauthenticated) do
    conn
  end

  def verify_condition(conn, :authenticated) do
    conn
  end

  def verify_condition(conn, {:authorized, _permissions}) do
    conn
  end

  # defp unauthorized(conn) do
  #   conn
  #   |> put_status(:not_found)
  #   |> put_flash(:error, "You are not authorized to access this page.")
  #   |> redirect(to: Routes.user_session_path(conn, :new))
  #   |> halt()
  # end
end
