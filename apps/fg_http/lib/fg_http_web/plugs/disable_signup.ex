defmodule FgHttpWeb.Plugs.DisableSignup do
  @moduledoc """
  Returns 403 when signups are disabled
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  alias FgHttpWeb.Router.Helpers, as: Routes

  def init(default), do: default

  def call(conn, _default) do
    case Application.get_env(:fg_http, :disable_signup) do
      true ->
        conn
        |> clear_session()
        |> put_flash(:error, "Signups are disabled. Contact your administrator for access.")
        |> redirect(to: Routes.session_path(conn, :new))
        |> halt()

      _ ->
        conn
    end
  end
end
