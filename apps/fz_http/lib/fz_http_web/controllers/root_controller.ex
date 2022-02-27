defmodule FzHttpWeb.RootController do
  @moduledoc """
  Handles redirecting from /
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    conn
    |> render(
      "auth.html",
      okta_enabled: okta_enabled(),
      google_enabled: google_enabled()
    )
  end

  defp okta_enabled do
    is_list(Application.get_env(:ueberauth, Ueberauth.Strategy.Okta.OAuth))
  end

  defp google_enabled do
    is_list(Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth))
  end
end
