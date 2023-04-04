defmodule Web.Auth.HTML.ErrorHandler do
  @moduledoc """
  HTML Error Handler module implementation for Guardian.
  """

  use Web, :controller
  alias Web.Auth.HTML.Authentication
  import Web.ControllerHelpers, only: [root_path_for_user: 1]
  require Logger

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {:already_authenticated, _reason}, _opts) do
    if subject = Authentication.get_current_subject(conn) do
      {:user, user} = subject.actor
      redirect(conn, to: root_path_for_user(user))
    else
      redirect(conn, to: root_path_for_user(nil))
    end
  end

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {:unauthenticated, _reason}, _opts) do
    conn
    |> redirect(to: ~p"/")
  end

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    Logger.info("Web auth error. Type: #{type}. Reason: #{reason}.")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, to_string(type))
  end
end
