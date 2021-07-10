defmodule FzHttp.Email do
  @moduledoc """
  Handles Email for the app
  """

  use Bamboo.Phoenix, view: FzHttpWeb.EmailView
  alias FzHttp.Users.PasswordReset

  @from "noreply@#{Application.compile_env(:fz_http, FzHttpWeb.Endpoint)[:url][:host]}"

  defp base_email(to) do
    new_email()
    |> put_html_layout({FzHttpWeb.LayoutView, "email.html"})
    |> from(@from)
    |> to(to)
  end

  def password_reset(%PasswordReset{} = password_reset) do
    base_email(password_reset.email)
    |> subject("FireZone password reset")
    |> assign(:reset_token, password_reset.reset_token)
    |> render(:password_reset)
  end
end
